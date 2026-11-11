#![cfg(windows)]

use std::time::Duration;
use std::{
    env,
    sync::atomic::{AtomicBool, Ordering},
    thread,
};

use windows_sys::Win32::System::Console::{SetConsoleCtrlHandler, CTRL_BREAK_EVENT};
use zignite::process::{run_argv, CommandSpec, TimeoutPolicy};

static CTRL_BREAK_RECEIVED: AtomicBool = AtomicBool::new(false);

unsafe extern "system" fn record_ctrl_break(event: u32) -> i32 {
    if event == CTRL_BREAK_EVENT {
        CTRL_BREAK_RECEIVED.store(true, Ordering::SeqCst);
        1
    } else {
        0
    }
}

#[test]
fn timeout_uses_windows_process_job_cleanup() {
    let spec = CommandSpec {
        argv: vec![
            "cmd.exe".into(),
            "/C".into(),
            "ping -n 10 127.0.0.1 > NUL".into(),
        ],
        cwd: None,
        env: Vec::new(),
    };

    let result = run_argv(
        &spec,
        TimeoutPolicy {
            timeout: Some(Duration::from_millis(50)),
            grace: Duration::from_millis(50),
        },
        None,
    )
    .expect("timed out process should return");

    assert!(result.timed_out);
}

#[test]
fn ctrl_break_child_helper() {
    if env::var_os("ZIGNITE_CTRL_BREAK_HELPER").is_none() {
        return;
    }
    let registered = unsafe { SetConsoleCtrlHandler(Some(record_ctrl_break), 1) };
    assert_ne!(registered, 0, "register CTRL_BREAK handler");

    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while !CTRL_BREAK_RECEIVED.load(Ordering::SeqCst) && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert!(
        CTRL_BREAK_RECEIVED.load(Ordering::SeqCst),
        "CTRL_BREAK was not delivered"
    );
}

#[test]
fn timeout_allows_console_child_to_exit_within_grace_period() {
    let executable = env::current_exe().expect("current test executable");
    let spec = CommandSpec {
        argv: vec![
            executable.into_os_string(),
            "--exact".into(),
            "ctrl_break_child_helper".into(),
            "--nocapture".into(),
        ],
        cwd: None,
        env: vec![("ZIGNITE_CTRL_BREAK_HELPER".into(), "1".into())],
    };
    let result = run_argv(
        &spec,
        TimeoutPolicy {
            timeout: Some(Duration::from_secs(3)),
            grace: Duration::from_secs(2),
        },
        None,
    )
    .expect("timed-out helper should return a process result");

    assert!(result.timed_out);
    assert!(
        result.status.success(),
        "the helper should handle CTRL_BREAK and exit during grace"
    );
}
