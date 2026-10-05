use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

pub struct ProcessTree;

impl ProcessTree {
    pub fn new(_child: &Child) -> io::Result<Self> {
        Ok(Self)
    }

    pub fn terminate(&mut self, child: &mut Child, grace: Duration) -> io::Result<()> {
        if child.try_wait()?.is_some() {
            return Ok(());
        }

        let process_group = -(child.id() as libc::pid_t);
        if unsafe { libc::kill(process_group, libc::SIGTERM) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }

        let deadline = Instant::now() + grace;
        while Instant::now() < deadline {
            if child.try_wait()?.is_some() {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(5));
        }

        if child.try_wait()?.is_none() && unsafe { libc::kill(process_group, libc::SIGKILL) } == -1
        {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }
        Ok(())
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
