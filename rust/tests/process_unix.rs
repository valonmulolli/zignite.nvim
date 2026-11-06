#![cfg(unix)]

use std::fs;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
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
fn interactive_terminal_helper() {
    if std::env::var_os("ZIGNITE_INTERACTIVE_PTY_HELPER").is_none() {
        return;
    }

    let spec = CommandSpec {
        argv: vec![
            "sh".into(),
            "-c".into(),
            "printf 'Enter: '; IFS= read -r value; printf 'Double %s is: %s\\n' \"$value\" \"$((value * 2))\"".into(),
        ],
        cwd: None,
        env: Vec::new(),
    };
    let result = run_terminal_command(
        &spec,
        TimeoutPolicy {
            timeout: Some(Duration::from_millis(750)),
            grace: Duration::from_millis(50),
        },
    )
    .expect("interactive terminal command should finish");

    assert!(!result.timed_out, "terminal input was not delivered");
    assert!(result.status.success());
}

#[test]
fn terminal_command_forwards_interactive_stdin() {
    let mut master_fd = -1;
    let mut slave_fd = -1;
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        },
        0,
        "openpty failed: {}",
        io::Error::last_os_error()
    );

    let mut master = unsafe { File::from_raw_fd(master_fd) };
    let slave = unsafe { File::from_raw_fd(slave_fd) };
    let flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
    assert_ne!(flags, -1, "fcntl(F_GETFL) failed");
    assert_eq!(
        unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0,
        "fcntl(F_SETFL) failed"
    );

    let slave_stdin = slave.try_clone().expect("clone PTY slave");
    let slave_stdout = slave.try_clone().expect("clone PTY slave");
    let mut helper = Command::new(std::env::current_exe().expect("test executable path"));
    helper
        .args(["--exact", "interactive_terminal_helper", "--nocapture"])
        .env("ZIGNITE_INTERACTIVE_PTY_HELPER", "1")
        .stdin(Stdio::from(slave_stdin))
        .stdout(Stdio::from(slave_stdout))
        .stderr(Stdio::from(slave));
    unsafe {
        helper.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut helper = helper.spawn().expect("spawn PTY helper");

    let prompt = read_until(
        &mut master,
        b"Enter: ",
        Instant::now() + Duration::from_secs(3),
    )
    .expect("interactive command did not print its prompt");
    master.write_all(b"2\n").expect("send terminal input");
    let output = read_until(
        &mut master,
        b"Double 2 is: 4",
        Instant::now() + Duration::from_secs(3),
    )
    .unwrap_or_else(|error| {
        let _ = unsafe { libc::kill(-(helper.id() as libc::pid_t), libc::SIGKILL) };
        let _ = helper.wait();
        panic!("interactive input was not processed; prompt={prompt:?}, error={error}");
    });

    assert!(output
        .windows(b"Double 2 is: 4".len())
        .any(|part| part == b"Double 2 is: 4"));
    let status = helper.wait().expect("wait for PTY helper");
    assert!(status.success(), "PTY helper failed: {status}");
}

fn read_until(file: &mut File, expected: &[u8], deadline: Instant) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut chunk = [0; 1024];
    loop {
        if output.windows(expected.len()).any(|part| part == expected) {
            return Ok(output);
        }
        if Instant::now() >= deadline {
            return Err(io::ErrorKind::TimedOut.into());
        }
        match file.read(&mut chunk) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => output.extend_from_slice(&chunk[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(error) => return Err(error),
        }
    }
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
