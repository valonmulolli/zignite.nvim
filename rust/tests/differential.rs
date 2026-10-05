use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::Value;

fn rust_backend() -> PathBuf {
    std::env::var_os("CARGO_BIN_EXE_zignite")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("target/debug/zignite"))
}

fn run_backend(
    executable: &Path,
    args: &[String],
    input: &str,
) -> (std::process::ExitStatus, String, String) {
    let mut child = Command::new(executable)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| panic!("spawn {}: {error}", executable.display()));
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        stdin
            .write_all(input.as_bytes())
            .expect("write backend input");
    }
    let output = child.wait_with_output().expect("wait for backend");
    (
        output.status,
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

fn result_json(stdout: &str) -> Value {
    let line = stdout
        .lines()
        .find_map(|line| line.strip_prefix("RESULT_JSON\t"))
        .unwrap_or_else(|| panic!("backend did not emit RESULT_JSON: {stdout}"));
    serde_json::from_str(line)
        .unwrap_or_else(|error| panic!("invalid backend JSON: {error}: {line}"))
}

fn fixture_root(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "zignite-differential-{name}-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create differential fixture");
    root
}

fn build_args(root: &Path, mode: &str) -> Vec<String> {
    let mut args = vec![
        mode.to_owned(),
        format!("--path={}", root.join("main.cpp").display()),
        "--filetype=cpp".to_owned(),
        "--config-stdin".to_owned(),
        "--config-revision=1".to_owned(),
    ];
    if mode == "--build-action" {
        args.extend([
            "--action=named".to_owned(),
            "--command-name=custom".to_owned(),
        ]);
    }
    args
}

#[test]
fn rust_backend_emits_normalized_build_records() {
    let root = fixture_root("rust");
    fs::write(root.join("main.cpp"), "int main() {}\n").expect("write source");
    fs::write(root.join("Makefile"), "build:\n\t@true\n").expect("write makefile");
    let config = r#"{"build_commands":{"cpp":{"custom":"make custom"}}}"#;
    let (status, stdout, stderr) = run_backend(
        &rust_backend(),
        &build_args(&root, "--build-resolve"),
        config,
    );
    assert!(status.success(), "backend failed: {stderr}");
    let json = result_json(&stdout);
    assert_eq!(json["ok"], true);
    assert_eq!(json["filetype"], "cpp");
    assert_eq!(json["config_revision"], 1);
    assert_eq!(json["commands"]["custom"], "make custom");
    assert!(json["command_meta"]["custom"].is_object());
    assert!(json["command_entries"]
        .as_array()
        .is_some_and(|entries| { entries.iter().any(|entry| entry["name"] == "custom") }));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn rust_backend_build_action_returns_direct_execution_record() {
    let root = fixture_root("action");
    fs::write(root.join("main.cpp"), "int main() {}\n").expect("write source");
    let config = r#"{"build_commands":{"cpp":{"custom":"echo custom"}}}"#;
    let (status, stdout, stderr) = run_backend(
        &rust_backend(),
        &build_args(&root, "--build-action"),
        config,
    );
    assert!(status.success(), "backend failed: {stderr}");
    let json = result_json(&stdout);
    assert_eq!(json["ok"], true);
    assert_eq!(json["resolved_command_name"], "custom");
    assert_eq!(json["exec_argv"][0], "echo");
    assert_eq!(json["exec_argv"][1], "custom");
    assert_eq!(json["system_argv"][0], "echo");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn rust_and_legacy_backends_match_normalized_build_contract_when_configured() {
    let Some(legacy) = std::env::var_os("ZIGNITE_LEGACY_BACKEND").map(PathBuf::from) else {
        eprintln!("skipping legacy differential comparison: ZIGNITE_LEGACY_BACKEND is unset");
        return;
    };
    let root = fixture_root("legacy");
    fs::write(root.join("main.cpp"), "int main() {}\n").expect("write source");
    let config = r#"{"build_commands":{"cpp":{"custom":"make custom"}}}"#;
    let args = build_args(&root, "--build-resolve");
    let (rust_status, rust_stdout, rust_stderr) = run_backend(&rust_backend(), &args, config);
    let (legacy_status, legacy_stdout, legacy_stderr) = run_backend(&legacy, &args, config);
    assert!(rust_status.success(), "Rust backend failed: {rust_stderr}");
    assert!(
        legacy_status.success(),
        "legacy backend failed: {legacy_stderr}"
    );

    let rust = result_json(&rust_stdout);
    let legacy = result_json(&legacy_stdout);
    for key in ["ok", "filetype", "config_revision"] {
        assert_eq!(rust[key], legacy[key], "differential mismatch in {key}");
    }
    assert_eq!(
        rust["commands"]["custom"], legacy["commands"]["custom"],
        "configured command changed between backends"
    );
    let _ = fs::remove_dir_all(root);
}
