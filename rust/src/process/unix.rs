use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

pub struct ProcessTree {
    process_group: libc::pid_t,
    active: bool,
}

pub struct TerminalForeground {
    terminal_fd: libc::c_int,
    previous_process_group: libc::pid_t,
    previous_sigttou: libc::sigaction,
}

impl TerminalForeground {
    pub fn new(child: &Child) -> io::Result<Option<Self>> {
        let terminal_fd = libc::STDIN_FILENO;
        if unsafe { libc::isatty(terminal_fd) } != 1 {
            return Ok(None);
        }

        let previous_process_group = unsafe { libc::tcgetpgrp(terminal_fd) };
        if previous_process_group == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ENOTTY) {
                return Ok(None);
            }
            return Err(error);
        }

        let previous_sigttou = ignore_sigttou()?;
        let process_group = child.id() as libc::pid_t;
        if unsafe { libc::tcsetpgrp(terminal_fd, process_group) } == -1 {
            let error = io::Error::last_os_error();
            restore_sigttou(&previous_sigttou);
            return Err(error);
        }

        let foreground = Self {
            terminal_fd,
            previous_process_group,
            previous_sigttou,
        };

        // The child may have stopped on SIGTTIN before the foreground handoff.
        if unsafe { libc::kill(-process_group, libc::SIGCONT) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }

        Ok(Some(foreground))
    }
}

impl Drop for TerminalForeground {
    fn drop(&mut self) {
        // The supervisor is in the background group while its child owns the terminal.
        let _ = unsafe { libc::tcsetpgrp(self.terminal_fd, self.previous_process_group) };
        restore_sigttou(&self.previous_sigttou);
    }
}

fn ignore_sigttou() -> io::Result<libc::sigaction> {
    let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
    action.sa_sigaction = libc::SIG_IGN;
    unsafe { libc::sigemptyset(&mut action.sa_mask) };

    let mut previous: libc::sigaction = unsafe { std::mem::zeroed() };
    if unsafe { libc::sigaction(libc::SIGTTOU, &action, &mut previous) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(previous)
}

fn restore_sigttou(previous: &libc::sigaction) {
    let _ = unsafe { libc::sigaction(libc::SIGTTOU, previous, std::ptr::null_mut()) };
}

impl ProcessTree {
    pub fn new(child: &Child) -> io::Result<Self> {
        Ok(Self {
            process_group: child.id() as libc::pid_t,
            active: true,
        })
    }

    pub fn terminate(&mut self, child: &mut Child, grace: Duration) -> io::Result<()> {
        if !self.active {
            return Ok(());
        }

        if !signal_group(self.process_group, libc::SIGTERM)? {
            self.active = false;
            return Ok(());
        }

        let deadline = Instant::now() + grace;
        while Instant::now() < deadline {
            let _ = child.try_wait()?;
            if !group_exists(self.process_group)? {
                self.active = false;
                return Ok(());
            }
            thread::sleep(Duration::from_millis(5));
        }

        signal_group(self.process_group, libc::SIGKILL)?;
        self.active = false;
        Ok(())
    }
}

impl Drop for ProcessTree {
    fn drop(&mut self) {
        if self.active {
            let _ = signal_group(self.process_group, libc::SIGKILL);
        }
    }
}

fn signal_group(process_group: libc::pid_t, signal: libc::c_int) -> io::Result<bool> {
    if unsafe { libc::kill(-process_group, signal) } == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH | libc::EPERM) => {
            // The group may disappear or become inaccessible between cleanup probes.
            // Do not fail the runner or risk acting on a process group we cannot verify.
            Ok(false)
        }
        _ => Err(io::Error::new(
            error.kind(),
            format!("signal {signal} to process group {process_group}: {error}"),
        )),
    }
}

fn group_exists(process_group: libc::pid_t) -> io::Result<bool> {
    if unsafe { libc::kill(-process_group, 0) } == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(false),
        Some(libc::EPERM) => Ok(true),
        _ => Err(error),
    }
}

pub fn configure_command(command: &mut Command) {
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}
