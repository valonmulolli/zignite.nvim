use std::ffi::OsString;
use std::fmt;
use std::fs;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::sync::atomic::AtomicBool;

static TEMP_DIR_SEQUENCE: AtomicU64 = AtomicU64::new(0);

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
    pub cancelled: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
pub struct TimeoutPolicy {
    pub timeout: Option<Duration>,
    pub grace: Duration,
}

struct ExecutionTempDir(PathBuf);

impl ExecutionTempDir {
    fn create() -> io::Result<Self> {
        for _ in 0..128 {
            let sequence = TEMP_DIR_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("zignite-run-{}-{sequence}", std::process::id()));
            let result = create_private_dir(&path);
            match result {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not allocate a unique execution directory",
        ))
    }
}

impl Drop for ExecutionTempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
fn create_private_dir(path: &std::path::Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;

    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700).create(path)
}

#[cfg(not(unix))]
fn create_private_dir(path: &std::path::Path) -> io::Result<()> {
    fs::create_dir(path)
}

fn append_command_args(command: &mut Command, spec: &CommandSpec) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        let is_cmd_command = spec.argv.len() == 3
            && spec.argv[0]
                .to_string_lossy()
                .eq_ignore_ascii_case("cmd.exe")
            && spec.argv[1].to_string_lossy().eq_ignore_ascii_case("/C");
        if is_cmd_command {
            command.arg(&spec.argv[1]).raw_arg(&spec.argv[2]);
            return;
        }
    }

    command.args(&spec.argv[1..]);
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
    run_argv_inner(spec, policy, stdin, false)
}

fn run_argv_inner(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
    stdin: Option<&[u8]>,
    watch_signals: bool,
) -> Result<ProcessResult, ProcessError> {
    let program = spec.argv.first().ok_or(ProcessError::EmptyCommand)?;
    let mut command = Command::new(program);
    append_command_args(&mut command, spec);
    if let Some(cwd) = &spec.cwd {
        command.current_dir(cwd);
    }
    command
        .envs(spec.env.iter().map(|(key, value)| (key, value)))
        .env_remove("ZIGNITE_PROCESS_GROUP_FILE");
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
                if error.kind() != io::ErrorKind::BrokenPipe {
                    let _ = tree.terminate(&mut child, policy.grace);
                    let _ = child.wait();
                    let _ = stdout_thread.join();
                    let _ = stderr_thread.join();
                    return Err(ProcessError::Io(error.to_string()));
                }
            }
        }
    }

    let (status, timed_out, cancelled) =
        wait_for_child(&mut child, &mut tree, policy, watch_signals)?;
    if !timed_out {
        tree.terminate(&mut child, policy.grace)
            .map_err(|error| ProcessError::Io(error.to_string()))?;
    }
    let stdout = join_reader(stdout_thread)?;
    let stderr = join_reader(stderr_thread)?;

    Ok(ProcessResult {
        status,
        timed_out,
        cancelled,
        stdout,
        stderr,
    })
}

pub fn run_terminal_command(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
) -> Result<ProcessResult, ProcessError> {
    let program = spec.argv.first().ok_or(ProcessError::EmptyCommand)?;
    let mut command = Command::new(program);
    append_command_args(&mut command, spec);
    if let Some(cwd) = &spec.cwd {
        command.current_dir(cwd);
    }
    command
        .envs(spec.env.iter().map(|(key, value)| (key, value)))
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
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
    #[cfg(unix)]
    let _terminal_foreground = match platform::TerminalForeground::new(&child) {
        Ok(foreground) => foreground,
        Err(error) => {
            let _ = tree.terminate(&mut child, policy.grace);
            let _ = child.wait();
            return Err(ProcessError::Io(error.to_string()));
        }
    };

    let (status, timed_out, cancelled) = wait_for_child(&mut child, &mut tree, policy, true)?;
    if !timed_out {
        tree.terminate(&mut child, policy.grace)
            .map_err(|error| ProcessError::Io(error.to_string()))?;
    }

    Ok(ProcessResult {
        status,
        timed_out,
        cancelled,
        stdout: Vec::new(),
        stderr: Vec::new(),
    })
}

pub fn run_backend_command(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
    stdin: Option<&[u8]>,
    cleanup: Option<&CommandSpec>,
) -> Result<ProcessResult, ProcessError> {
    let (spec, cleanup, _temp_dir) = prepare_execution_commands(spec, cleanup)?;
    let result = run_argv(&spec, policy, stdin);
    let cleanup_result = cleanup
        .as_ref()
        .map(|command| run_argv(command, policy, None));
    preserve_primary_result(result, cleanup_result)
}

pub fn run_backend_terminal_command(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
    cleanup: Option<&CommandSpec>,
) -> Result<ProcessResult, ProcessError> {
    #[cfg(unix)]
    let _signal_guard =
        TerminalSignalGuard::install().map_err(|error| ProcessError::Io(error.to_string()))?;

    let (spec, cleanup, _temp_dir) = prepare_execution_commands(spec, cleanup)?;
    let result = run_terminal_command(&spec, policy);
    #[cfg(unix)]
    if result.as_ref().is_ok_and(|result| result.cancelled) {
        TERMINAL_STOP_REQUESTED.store(false, Ordering::SeqCst);
    }
    let cleanup_result = cleanup
        .as_ref()
        .map(|command| run_argv_inner(command, policy, None, true));

    preserve_primary_result(result, cleanup_result)
}

fn prepare_execution_commands(
    spec: &CommandSpec,
    cleanup: Option<&CommandSpec>,
) -> Result<(CommandSpec, Option<CommandSpec>, Option<ExecutionTempDir>), ProcessError> {
    let uses_temp_dir = std::iter::once(spec).chain(cleanup).any(|command| {
        command
            .argv
            .iter()
            .any(|argument| argument.to_string_lossy().contains("ZIGNITE_TMPDIR"))
    });
    let temp_dir = if uses_temp_dir {
        Some(ExecutionTempDir::create().map_err(|error| ProcessError::Io(error.to_string()))?)
    } else {
        None
    };
    let spec = temp_dir
        .as_ref()
        .map_or_else(|| spec.clone(), |directory| with_temp_dir(spec, directory));
    let cleanup = cleanup.map(|command| {
        temp_dir.as_ref().map_or_else(
            || command.clone(),
            |directory| with_temp_dir(command, directory),
        )
    });
    Ok((spec, cleanup, temp_dir))
}

fn with_temp_dir(spec: &CommandSpec, directory: &ExecutionTempDir) -> CommandSpec {
    let mut spec = spec.clone();
    spec.env
        .retain(|(key, _)| key != std::ffi::OsStr::new("ZIGNITE_TMPDIR"));
    spec.env.push((
        OsString::from("ZIGNITE_TMPDIR"),
        directory.0.as_os_str().to_owned(),
    ));
    spec
}

fn preserve_primary_result(
    result: Result<ProcessResult, ProcessError>,
    cleanup_result: Option<Result<ProcessResult, ProcessError>>,
) -> Result<ProcessResult, ProcessError> {
    let result = result?;
    if !result.status.success() {
        return Ok(result);
    }

    if let Some(cleanup_result) = cleanup_result {
        let cleanup_result = cleanup_result?;
        if !cleanup_result.status.success() {
            return Err(ProcessError::CleanupFailed {
                code: cleanup_result.status.code(),
            });
        }
    }

    Ok(result)
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
    watch_signals: bool,
) -> Result<(ExitStatus, bool, bool), ProcessError> {
    if policy.timeout.is_none() && !watch_signals {
        return child
            .wait()
            .map(|status| (status, false, false))
            .map_err(|error| ProcessError::Io(error.to_string()));
    }

    let started = Instant::now();
    loop {
        if watch_signals && terminal_stop_requested() {
            // Neovim escalates jobstop() to SIGKILL after a short grace period.
            // Finish the child tree cleanup before that can kill this supervisor.
            tree.terminate(child, Duration::from_millis(25))
                .map_err(|error| ProcessError::Io(error.to_string()))?;
            let status = child
                .wait()
                .map_err(|error| ProcessError::Io(error.to_string()))?;
            return Ok((status, false, true));
        }
        if let Some(status) = child
            .try_wait()
            .map_err(|error| ProcessError::Io(error.to_string()))?
        {
            return Ok((status, false, false));
        }
        if policy
            .timeout
            .is_some_and(|timeout| started.elapsed() >= timeout)
        {
            tree.terminate(child, policy.grace)
                .map_err(|error| ProcessError::Io(error.to_string()))?;
            let status = child
                .wait()
                .map_err(|error| ProcessError::Io(error.to_string()))?;
            return Ok((status, true, false));
        }
        thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
static TERMINAL_STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn terminal_signal_handler(_: libc::c_int) {
    TERMINAL_STOP_REQUESTED.store(true, Ordering::SeqCst);
}

#[cfg(unix)]
struct TerminalSignalGuard {
    previous_term: std::mem::MaybeUninit<libc::sigaction>,
    previous_int: std::mem::MaybeUninit<libc::sigaction>,
    previous_hup: std::mem::MaybeUninit<libc::sigaction>,
    previous_mask: std::mem::MaybeUninit<libc::sigset_t>,
}

#[cfg(unix)]
impl TerminalSignalGuard {
    fn install() -> io::Result<Self> {
        use std::mem::MaybeUninit;

        TERMINAL_STOP_REQUESTED.store(false, Ordering::SeqCst);
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = terminal_signal_handler as *const () as usize;
        unsafe { libc::sigemptyset(&mut action.sa_mask) };

        let mut stop_signals: libc::sigset_t = unsafe { std::mem::zeroed() };
        unsafe {
            libc::sigemptyset(&mut stop_signals);
            libc::sigaddset(&mut stop_signals, libc::SIGTERM);
            libc::sigaddset(&mut stop_signals, libc::SIGINT);
            libc::sigaddset(&mut stop_signals, libc::SIGHUP);
        }
        let mut previous_mask = MaybeUninit::uninit();
        let mask_result = unsafe {
            libc::pthread_sigmask(libc::SIG_UNBLOCK, &stop_signals, previous_mask.as_mut_ptr())
        };
        if mask_result != 0 {
            return Err(io::Error::from_raw_os_error(mask_result));
        }

        let mut previous_term = MaybeUninit::uninit();
        if unsafe { libc::sigaction(libc::SIGTERM, &action, previous_term.as_mut_ptr()) } == -1 {
            let error = io::Error::last_os_error();
            unsafe {
                libc::pthread_sigmask(
                    libc::SIG_SETMASK,
                    previous_mask.as_ptr(),
                    std::ptr::null_mut(),
                );
            }
            return Err(error);
        }
        let mut previous_int = MaybeUninit::uninit();
        if unsafe { libc::sigaction(libc::SIGINT, &action, previous_int.as_mut_ptr()) } == -1 {
            let error = io::Error::last_os_error();
            unsafe { libc::sigaction(libc::SIGTERM, previous_term.as_ptr(), std::ptr::null_mut()) };
            unsafe {
                libc::pthread_sigmask(
                    libc::SIG_SETMASK,
                    previous_mask.as_ptr(),
                    std::ptr::null_mut(),
                );
            }
            return Err(error);
        }
        let mut previous_hup = MaybeUninit::uninit();
        if unsafe { libc::sigaction(libc::SIGHUP, &action, previous_hup.as_mut_ptr()) } == -1 {
            let error = io::Error::last_os_error();
            unsafe {
                libc::sigaction(libc::SIGINT, previous_int.as_ptr(), std::ptr::null_mut());
                libc::sigaction(libc::SIGTERM, previous_term.as_ptr(), std::ptr::null_mut());
                libc::pthread_sigmask(
                    libc::SIG_SETMASK,
                    previous_mask.as_ptr(),
                    std::ptr::null_mut(),
                );
            }
            return Err(error);
        }
        Ok(Self {
            previous_term,
            previous_int,
            previous_hup,
            previous_mask,
        })
    }
}

#[cfg(unix)]
impl Drop for TerminalSignalGuard {
    fn drop(&mut self) {
        unsafe {
            libc::sigaction(
                libc::SIGTERM,
                self.previous_term.as_ptr(),
                std::ptr::null_mut(),
            );
            libc::sigaction(
                libc::SIGINT,
                self.previous_int.as_ptr(),
                std::ptr::null_mut(),
            );
            libc::sigaction(
                libc::SIGHUP,
                self.previous_hup.as_ptr(),
                std::ptr::null_mut(),
            );
            libc::pthread_sigmask(
                libc::SIG_SETMASK,
                self.previous_mask.as_ptr(),
                std::ptr::null_mut(),
            );
        }
        TERMINAL_STOP_REQUESTED.store(false, Ordering::SeqCst);
    }
}

#[cfg(unix)]
fn terminal_stop_requested() -> bool {
    TERMINAL_STOP_REQUESTED.load(Ordering::SeqCst)
}

#[cfg(not(unix))]
fn terminal_stop_requested() -> bool {
    false
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

#[cfg(all(test, unix))]
mod tests {
    use super::{run_terminal_command, CommandSpec, TimeoutPolicy, TERMINAL_STOP_REQUESTED};
    use std::sync::atomic::Ordering;
    use std::time::{Duration, Instant};

    #[test]
    fn terminal_runner_stops_its_process_group_when_cancellation_is_requested() {
        TERMINAL_STOP_REQUESTED.store(true, Ordering::SeqCst);
        let spec = CommandSpec {
            argv: vec!["sh".into(), "-c".into(), "sleep 10".into()],
            cwd: None,
            env: Vec::new(),
        };
        let started = Instant::now();

        let result = run_terminal_command(
            &spec,
            TimeoutPolicy {
                timeout: None,
                grace: Duration::from_millis(20),
            },
        )
        .expect("cancelled terminal command is reaped");

        assert!(result.cancelled);
        assert!(started.elapsed() < Duration::from_secs(2));
        TERMINAL_STOP_REQUESTED.store(false, Ordering::SeqCst);
    }
}
