#![cfg(unix)]

use std::fs;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use zignite::process::{
    run_argv, run_backend_terminal_command, run_terminal_command, CommandSpec, TimeoutPolicy,
};

#[test]
fn timeout_kills_descendants_in_the_process_group() {
    let marker = std::env::temp_dir().join(format!(
        "zignite-descendant-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos()
    ));
    let marker_text = marker.to_string_lossy().into_owned();
    let script = format!("(sleep .2; printf survived > '{}') & wait", marker_text);
    let spec = CommandSpec {
        argv: vec!["sh".into(), "-c".into(), script.into()],
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

    std::thread::sleep(Duration::from_millis(300));
    assert!(result.timed_out);
    assert!(!marker.exists(), "descendant survived timeout");
    let _ = fs::remove_file(marker);
}

#[test]
fn timeout_kills_term_ignoring_descendants_after_the_leader_exits() {
    let marker = std::env::temp_dir().join(format!(
        "zignite-ignored-term-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos()
    ));
    let marker_text = marker.to_string_lossy().into_owned();
    let script = format!(
        "sh -c 'trap \"\" TERM; (sleep .2; printf survived > \"{marker_text}\") >/dev/null 2>&1 & exec sleep 10 >/dev/null 2>&1' & wait"
    );
    let spec = CommandSpec {
        argv: vec!["sh".into(), "-c".into(), script.into()],
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

    std::thread::sleep(Duration::from_millis(300));
    assert!(result.timed_out);
    assert!(
        !marker.exists(),
        "TERM-ignoring descendant survived timeout"
    );
}

#[test]
fn command_exit_does_not_wait_for_background_descendants_holding_pipes() {
    let marker = std::env::temp_dir().join(format!(
        "zignite-background-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos()
    ));
    let marker_text = marker.to_string_lossy().into_owned();
    let script = format!("(sleep .3; printf survived > '{marker_text}') & exit 0");
    let spec = CommandSpec {
        argv: vec!["sh".into(), "-c".into(), script.into()],
        cwd: None,
        env: Vec::new(),
    };
    let started = Instant::now();

    run_argv(
        &spec,
        TimeoutPolicy {
            timeout: None,
            grace: Duration::from_millis(50),
        },
        None,
    )
    .expect("command should complete");

    assert!(started.elapsed() < Duration::from_millis(250));
    std::thread::sleep(Duration::from_millis(350));
    assert!(
        !marker.exists(),
        "background descendant outlived its command"
    );
}

#[test]
fn terminal_command_cleans_descendants_when_leader_exits() {
    let base = std::env::temp_dir().join(format!(
        "zignite-terminal-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos()
    ));
    let marker = base.with_extension("marker");
    let marker_text = marker.to_string_lossy().into_owned();
    let script = format!("(sleep .2; printf survived > '{marker_text}') >/dev/null 2>&1 & exit 0");
    let spec = CommandSpec {
        argv: vec!["sh".into(), "-c".into(), script.into()],
        cwd: None,
        env: Vec::new(),
    };

    let result = run_terminal_command(
        &spec,
        TimeoutPolicy {
            timeout: None,
            grace: Duration::from_millis(50),
        },
    )
    .expect("terminal command completes");

    assert!(result.status.success());
    assert!(!result.cancelled);
    std::thread::sleep(Duration::from_millis(300));
    assert!(!marker.exists(), "background descendant must be terminated");
}

#[test]
fn sigterm_helper_process() {
    let Ok(marker) = std::env::var("ZIGNITE_SIGTERM_MARKER") else {
        return;
    };
    let ready = std::env::var("ZIGNITE_SIGTERM_READY").expect("helper ready path provided");
    let script = format!("touch '{ready}'; (sleep .4; touch '{marker}') >/dev/null 2>&1 & wait");
    let spec = CommandSpec {
        argv: vec!["sh".into(), "-c".into(), script.into()],
        cwd: None,
        env: Vec::new(),
    };
    let result = run_backend_terminal_command(
        &spec,
        TimeoutPolicy {
            timeout: None,
            grace: Duration::from_millis(50),
        },
        None,
    )
    .expect("signal-cancelled terminal command should finish");
    assert!(result.cancelled);
}

#[test]
fn stopping_backend_job_reaps_terminal_command_descendants() {
    let base = std::env::temp_dir().join(format!(
        "zignite-sigterm-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos()
    ));
    let marker = base.with_extension("marker");
    let ready = base.with_extension("ready");
    let mut child = Command::new(std::env::current_exe().expect("test executable path"))
        .args(["--exact", "sigterm_helper_process", "--nocapture"])
        .env("ZIGNITE_SIGTERM_MARKER", &marker)
        .env("ZIGNITE_SIGTERM_READY", &ready)
        .spawn()
        .expect("spawn isolated signal helper");
    let deadline = Instant::now() + Duration::from_secs(3);
    while !ready.exists() && Instant::now() < deadline {
        if let Some(status) = child.try_wait().expect("poll helper") {
            panic!("signal helper exited before starting: {status}");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(ready.exists(), "helper did not start its terminal command");

    assert_eq!(
        unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) },
        0
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.try_wait().expect("poll helper exit") {
            assert!(status.success(), "helper did not handle SIGTERM: {status}");
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            panic!("backend helper did not exit after SIGTERM");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        !marker.exists(),
        "terminal descendant survived backend stop"
    );
}
