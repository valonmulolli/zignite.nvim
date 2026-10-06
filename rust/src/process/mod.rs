use std::ffi::OsString;
use std::fmt;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::sync::atomic::{AtomicBool, Ordering};

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
    command.args(&spec.argv[1..]);
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
                let _ = tree.terminate(&mut child, policy.grace);
                let _ = child.wait();
                let _ = stdout_thread.join();
                let _ = stderr_thread.join();
                return Err(ProcessError::Io(error.to_string()));
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
    command.args(&spec.argv[1..]);
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

pub fn run_backend_terminal_command(
    spec: &CommandSpec,
    policy: TimeoutPolicy,
    cleanup: Option<&CommandSpec>,
) -> Result<ProcessResult, ProcessError> {
    #[cfg(unix)]
    let _signal_guard =
        TerminalSignalGuard::install().map_err(|error| ProcessError::Io(error.to_string()))?;

    let result = run_terminal_command(spec, policy);
    #[cfg(unix)]
    if result.as_ref().is_ok_and(|result| result.cancelled) {
        TERMINAL_STOP_REQUESTED.store(false, Ordering::SeqCst);
    }
    let cleanup_result = cleanup.map(|command| run_argv_inner(command, policy, None, true));

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
