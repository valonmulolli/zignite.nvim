use std::ffi::OsString;
use std::fmt;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

#[cfg(unix)]
use unix as platform;
#[cfg(windows)]
use windows as platform;

#[derive(Debug, Clone)]
pub struct CommandSpec {
    pub argv: Vec<OsString>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(OsString, OsString)>,
}

#[derive(Debug)]
pub struct ProcessResult {
    pub status: ExitStatus,
    pub timed_out: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
pub struct TimeoutPolicy {
    pub timeout: Option<Duration>,
    pub grace: Duration,
}

#[derive(Debug)]
pub enum ProcessError {
    EmptyCommand,
    MissingExecutable { program: String },
    Io(String),
    ReaderThread,
    CleanupFailed { code: Option<i32> },
}

impl fmt::Display for ProcessError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyCommand => formatter.write_str("empty command"),
            Self::MissingExecutable { program } => {
                write!(formatter, "executable not found: {program}")
            }
            Self::Io(message) => write!(formatter, "process I/O error: {message}"),
            Self::ReaderThread => formatter.write_str("process output reader stopped unexpectedly"),
            Self::CleanupFailed { code } => write!(formatter, "cleanup command failed: {code:?}"),
        }
    }
}

impl std::error::Error for ProcessError {}

pub fn run_argv(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
    stdin: Option<&[u8]>,
) -> Result<ProcessResult, ProcessError> {
    let program = spec.argv.first().ok_or(ProcessError::EmptyCommand)?;
    let mut command = Command::new(program);
    command.args(&spec.argv[1..]);
    if let Some(cwd) = &spec.cwd {
        command.current_dir(cwd);
    }
    command.envs(spec.env.iter().map(|(key, value)| (key, value)));
    command
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    platform::configure_command(&mut command);

    let mut child = command.spawn().map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            ProcessError::MissingExecutable {
                program: program.to_string_lossy().into_owned(),
            }
        } else {
            ProcessError::Io(error.to_string())
        }
    })?;
    let mut tree = match platform::ProcessTree::new(&child) {
        Ok(tree) => tree,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ProcessError::Io(error.to_string()));
        }
    };

    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            let _ = tree.terminate(&mut child, policy.grace);
            let _ = child.wait();
            return Err(ProcessError::Io("stdout pipe unavailable".into()));
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            let _ = tree.terminate(&mut child, policy.grace);
            let _ = child.wait();
            return Err(ProcessError::Io("stderr pipe unavailable".into()));
        }
    };
    let stdout_thread = thread::spawn(move || read_pipe(stdout));
    let stderr_thread = thread::spawn(move || read_pipe(stderr));

    if let Some(input) = stdin {
        if let Some(mut child_stdin) = child.stdin.take() {
            if let Err(error) = child_stdin.write_all(input) {
                let _ = tree.terminate(&mut child, policy.grace);
                let _ = child.wait();
                let _ = stdout_thread.join();
                let _ = stderr_thread.join();
                return Err(ProcessError::Io(error.to_string()));
            }
        }
    }

    let (status, timed_out) = wait_for_child(&mut child, &mut tree, policy)?;
    let stdout = join_reader(stdout_thread)?;
    let stderr = join_reader(stderr_thread)?;

    Ok(ProcessResult {
        status,
        timed_out,
        stdout,
        stderr,
    })
}

pub fn run_backend_command(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
    stdin: Option<&[u8]>,
    cleanup: Option<&CommandSpec>,
) -> Result<ProcessResult, ProcessError> {
    let result = run_argv(spec, policy, stdin);
    let cleanup_result = cleanup.map(|command| run_argv(command, policy, None));

    if let Some(Err(error)) = cleanup_result {
        return Err(error);
    }
    if let Some(Ok(cleanup_result)) = cleanup_result {
        if !cleanup_result.status.success() {
            return Err(ProcessError::CleanupFailed {
                code: cleanup_result.status.code(),
            });
        }
    }
    result
}

pub fn shell_command(command: &str) -> CommandSpec {
    #[cfg(unix)]
    let argv = vec![
        OsString::from("/bin/sh"),
        OsString::from("-c"),
        OsString::from(command),
    ];
    #[cfg(windows)]
    let argv = vec![
        OsString::from("cmd.exe"),
        OsString::from("/C"),
        OsString::from(command),
    ];
    CommandSpec {
        argv,
        cwd: None,
        env: Vec::new(),
    }
}

fn wait_for_child(
    child: &mut std::process::Child,
    tree: &mut platform::ProcessTree,
    policy: TimeoutPolicy,
) -> Result<(ExitStatus, bool), ProcessError> {
    let Some(timeout) = policy.timeout else {
        return child
            .wait()
            .map(|status| (status, false))
            .map_err(|error| ProcessError::Io(error.to_string()));
    };

    let started = Instant::now();
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| ProcessError::Io(error.to_string()))?
        {
            return Ok((status, false));
        }
        if started.elapsed() >= timeout {
            tree.terminate(child, policy.grace)
                .map_err(|error| ProcessError::Io(error.to_string()))?;
            let status = child
                .wait()
                .map_err(|error| ProcessError::Io(error.to_string()))?;
            return Ok((status, true));
        }
        thread::sleep(Duration::from_millis(5));
    }
}

fn read_pipe<R: Read>(mut reader: R) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    reader.read_to_end(&mut output)?;
    Ok(output)
}

fn join_reader(handle: thread::JoinHandle<io::Result<Vec<u8>>>) -> Result<Vec<u8>, ProcessError> {
    match handle.join() {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(error)) => Err(ProcessError::Io(error.to_string())),
        Err(_) => Err(ProcessError::ReaderThread),
    }
}
