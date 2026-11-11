use std::io;
use std::os::windows::io::AsRawHandle;
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::Console::{GenerateConsoleCtrlEvent, CTRL_BREAK_EVENT};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicAccountingInformation,
    JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
    TerminateJobObject, JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::Threading::{
    OpenThread, ResumeThread, CREATE_NEW_PROCESS_GROUP, CREATE_SUSPENDED, THREAD_SUSPEND_RESUME,
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
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const _,
                std::mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            let error = io::Error::last_os_error();
            unsafe { CloseHandle(job) };
            return Err(error);
        }
        let process = child.as_raw_handle() as HANDLE;
        if unsafe { AssignProcessToJobObject(job, process) } == 0 {
            let error = io::Error::last_os_error();
            unsafe { CloseHandle(job) };
            return Err(error);
        }
        if let Err(error) = resume_initial_thread(child.id()) {
            // Closing a kill-on-close job also cleans up the still-suspended child.
            unsafe { CloseHandle(job) };
            return Err(error);
        }
        Ok(Self { job })
    }

    pub fn terminate(&mut self, child: &mut Child, grace: Duration) -> io::Result<()> {
        if grace.is_zero() {
            return self.force_terminate();
        }

        // Console control is best-effort; headless children are force-killed after grace.
        unsafe {
            GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, child.id());
        }
        let started = Instant::now();
        while started.elapsed() < grace {
            if self.is_empty().unwrap_or(false) {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(10).min(grace.saturating_sub(started.elapsed())));
        }
        self.force_terminate()
    }

    fn is_empty(&self) -> io::Result<bool> {
        let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = unsafe { std::mem::zeroed() };
        if unsafe {
            QueryInformationJobObject(
                self.job,
                JobObjectBasicAccountingInformation,
                &mut accounting as *mut _ as *mut _,
                std::mem::size_of_val(&accounting) as u32,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(accounting.ActiveProcesses == 0)
    }

    fn force_terminate(&self) -> io::Result<()> {
        if unsafe { TerminateJobObject(self.job, 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

fn resume_initial_thread(process_id: u32) -> io::Result<()> {
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;

    // `Command` exposes the process handle but not its initial thread handle.
    // The process is suspended, so it can have no other threads yet.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }

    let result = (|| {
        let mut entry: THREADENTRY32 = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
        if unsafe { Thread32First(snapshot, &mut entry) } == 0 {
            return Err(io::Error::last_os_error());
        }

        loop {
            if entry.th32OwnerProcessID == process_id {
                let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if thread.is_null() {
                    return Err(io::Error::last_os_error());
                }

                let resume_result = unsafe { ResumeThread(thread) };
                let resume_error = if resume_result == u32::MAX {
                    Some(io::Error::last_os_error())
                } else if resume_result != 1 {
                    Some(io::Error::new(
                        io::ErrorKind::Other,
                        "child thread had an unexpected suspend count",
                    ))
                } else {
                    None
                };
                unsafe { CloseHandle(thread) };
                return resume_error.map_or(Ok(()), Err);
            }
            if unsafe { Thread32Next(snapshot, &mut entry) } == 0 {
                break;
            }
        }

        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "suspended process thread was not found",
        ))
    })();

    unsafe { CloseHandle(snapshot) };
    result
}

impl Drop for ProcessTree {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.job) };
    }
}

pub fn configure_command(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    command.creation_flags(CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP);
}

#[cfg(test)]
mod tests {
    use super::{configure_command, ProcessTree};
    use std::fs;
    use std::process::{Command, Stdio};
    use std::thread;
    use std::time::Duration;

    #[test]
    fn child_does_not_run_before_job_assignment() {
        let marker = std::env::temp_dir().join(format!(
            "zignite-suspended-child-{}.txt",
            std::process::id()
        ));
        let _ = fs::remove_file(&marker);

        let script = format!("echo started > \"{}\"", marker.display());
        let mut command = Command::new("cmd.exe");
        command
            .args(["/C", &script])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        configure_command(&mut command);
        let mut child = command.spawn().expect("spawn suspended child");

        thread::sleep(Duration::from_millis(200));
        assert!(
            !marker.exists(),
            "child executed before it was assigned to the job"
        );

        let _tree = ProcessTree::new(&child).expect("assign and resume child");
        let status = child.wait().expect("wait for resumed child");
        assert!(status.success());
        assert!(marker.exists(), "child should execute after job assignment");

        fs::remove_file(marker).expect("remove marker");
    }
}
