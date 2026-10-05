#![cfg(windows)]

use std::time::Duration;

use zignite::process::{run_argv, CommandSpec, TimeoutPolicy};

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
