use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

pub struct ProcessTree {
    process_group: libc::pid_t,
    active: bool,
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
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(false)
    } else {
        Err(error)
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
