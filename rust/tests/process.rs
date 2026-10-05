use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use zignite::process::{run_argv, run_backend_command, CommandSpec, ProcessError, TimeoutPolicy};

fn command(program: &str, args: &[&str]) -> CommandSpec {
    let mut argv = vec![OsString::from(program)];
    argv.extend(args.iter().map(OsString::from));
    CommandSpec {
        argv,
        cwd: None,
        env: Vec::new(),
    }
}

fn no_timeout() -> TimeoutPolicy {
    TimeoutPolicy {
        timeout: None,
        grace: Duration::from_millis(100),
    }
}

fn shell(script: &str) -> CommandSpec {
    #[cfg(unix)]
    {
        command("sh", &["-c", script])
    }
    #[cfg(windows)]
    {
        command("cmd.exe", &["/C", script])
    }
}

fn hello_command() -> CommandSpec {
    #[cfg(unix)]
    {
        shell("printf hello")
    }
    #[cfg(windows)]
    {
        shell("echo hello")
    }
}

fn stdin_command() -> CommandSpec {
    #[cfg(unix)]
    {
        shell("cat")
    }
    #[cfg(windows)]
    {
        shell("more")
    }
}

fn timeout_command() -> CommandSpec {
    #[cfg(unix)]
    {
        shell("sleep 10")
    }
    #[cfg(windows)]
    {
        shell("ping -n 10 127.0.0.1 > NUL")
    }
}

fn empty_output_command() -> CommandSpec {
    #[cfg(unix)]
    {
        shell(":")
    }
    #[cfg(windows)]
    {
        shell("exit /B 0")
    }
}

fn unique_temp_path(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is after epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("zignite-{name}-{}-{nanos}", std::process::id()))
}

#[test]
fn process_returns_stdout_and_success_status() {
    let result = run_argv(&hello_command(), no_timeout(), None).expect("command succeeds");

    assert!(result.status.success());
    assert_eq!(String::from_utf8_lossy(&result.stdout).trim(), "hello");
}

#[test]
fn process_preserves_nonzero_exit_status() {
    let result = run_argv(&shell("exit 7"), no_timeout(), None).expect("command should spawn");

    assert_eq!(result.status.code(), Some(7));
}

#[test]
fn process_reports_missing_executable() {
    let result = run_argv(
        &command("zignite-command-that-does-not-exist", &[]),
        no_timeout(),
        None,
    );

    assert!(matches!(
        result,
        Err(ProcessError::MissingExecutable { .. })
    ));
}

#[test]
fn process_forwards_working_directory_and_environment() {
    let directory = unique_temp_path("cwd");
    fs::create_dir(&directory).expect("create temporary directory");
    let mut spec = shell("printf '%s:%s' \"$PWD\" \"$ZIGNITE_TEST_VALUE\"");
    #[cfg(windows)]
    {
        spec = shell("echo %CD%:%ZIGNITE_TEST_VALUE%");
    }
    spec.cwd = Some(directory.clone());
    spec.env.push((
        OsString::from("ZIGNITE_TEST_VALUE"),
        OsString::from("present"),
    ));

    let result = run_argv(&spec, no_timeout(), None).expect("command succeeds");
    let output = String::from_utf8_lossy(&result.stdout);

    assert!(output.contains(directory.to_string_lossy().as_ref()));
    assert!(output.contains("present"));
    fs::remove_dir(&directory).expect("remove temporary directory");
}

#[test]
fn process_forwards_stdin() {
    let result = run_argv(&stdin_command(), no_timeout(), Some(b"input"))
        .expect("command should receive stdin");

    assert_eq!(String::from_utf8_lossy(&result.stdout).trim(), "input");
}

#[test]
fn backend_command_runs_cleanup_after_primary_command() {
    let marker = unique_temp_path("cleanup");
    let marker_text = marker.to_string_lossy().into_owned();
    #[cfg(unix)]
    let cleanup = shell(&format!("printf cleaned > '{}'", marker_text));
    #[cfg(windows)]
    let cleanup = shell(&format!("echo cleaned>{marker_text}"));

    let result = run_backend_command(&hello_command(), no_timeout(), None, Some(&cleanup))
        .expect("primary and cleanup commands succeed");

    assert_eq!(String::from_utf8_lossy(&result.stdout).trim(), "hello");
    assert_eq!(
        fs::read_to_string(&marker)
            .expect("cleanup marker exists")
            .trim(),
        "cleaned"
    );
    fs::remove_file(marker).expect("remove cleanup marker");
}

#[test]
fn process_timeout_returns_after_killing_the_child() {
    let result = run_argv(
        &timeout_command(),
        TimeoutPolicy {
            timeout: Some(Duration::from_millis(50)),
            grace: Duration::from_millis(50),
        },
        None,
    )
    .expect("timed out command should still return a result");

    assert!(result.timed_out);
}

#[test]
fn process_preserves_empty_output() {
    let result = run_argv(&empty_output_command(), no_timeout(), None).expect("command succeeds");

    assert!(result.stdout.is_empty());
    assert!(result.stderr.is_empty());
}

#[allow(dead_code)]
fn path_exists(path: &Path) -> bool {
    path.exists()
}
