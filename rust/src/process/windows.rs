use std::io;
use std::os::windows::io::AsRawHandle;
use std::process::{Child, Command};
use std::time::Duration;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject,
};

pub struct ProcessTree {
    job: HANDLE,
}

impl ProcessTree {
    pub fn new(child: &Child) -> io::Result<Self> {
        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }
        let process = child.as_raw_handle() as HANDLE;
        if unsafe { AssignProcessToJobObject(job, process) } == 0 {
            let error = io::Error::last_os_error();
            unsafe { CloseHandle(job) };
            return Err(error);
        }
        Ok(Self { job })
    }

    pub fn terminate(&mut self, _child: &mut Child, _grace: Duration) -> io::Result<()> {
        if unsafe { TerminateJobObject(self.job, 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for ProcessTree {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.job) };
    }
}

pub fn configure_command(_command: &mut Command) {}
