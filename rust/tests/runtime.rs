use std::fs;
use std::io::Cursor;

use zignite::config::{apply_config_sync, ConfigState};
use zignite::runtime::materialize::materialize_runner;
use zignite::runtime::types::{ResolvedRunner, RunnerSource};
use zignite::runtime::{handle_run_frame, resolve_runner, zig_classifier};

#[test]
fn configured_runner_wins_and_materializes_file_variables() {
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        1,
        r#"{"runners":{"python":"python3 -u $file"}}"#,
    )
    .expect("config applies");

    let resolved = resolve_runner(&config, "/tmp/example dir/main.py", "python", None, None)
        .expect("runner resolves");

    assert_eq!(resolved.source, RunnerSource::Config);
    assert_eq!(
        resolved.command.as_deref(),
        Some("python3 -u '/tmp/example dir/main.py'")
    );
    assert_eq!(
        resolved.argv,
        vec![
            "python3".to_owned(),
            "-u".to_owned(),
            "/tmp/example dir/main.py".to_owned()
        ]
    );
}

#[test]
fn materialization_does_not_confuse_dir_name_with_dir() {
    let mut runner = ResolvedRunner {
        source: RunnerSource::Config,
        filetype: "python".to_owned(),
        command: Some("python3 $dir/$fileName $dirName".to_owned()),
        ..ResolvedRunner::default()
    };

    materialize_runner(&mut runner, "/tmp/example dir/main.py").expect("runner materializes");

    assert_eq!(
        runner.command.as_deref(),
        Some("python3 '/tmp/example dir'/'main.py' 'example dir'")
    );
}

#[test]
fn object_runner_command_array_remains_a_shell_sequence() {
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        1,
        r#"{"runners":{"java":{"cmd":["javac $file","java $fileNameWithoutExt"]}}}"#,
    )
    .expect("config applies");

    let resolved =
        resolve_runner(&config, "/tmp/Main.java", "java", None, None).expect("runner resolves");

    assert_eq!(
        resolved.command.as_deref(),
        Some("javac '/tmp/Main.java' && java 'Main'")
    );
    assert_eq!(
        resolved.argv,
        vec![
            "javac".to_owned(),
            "/tmp/Main.java".to_owned(),
            "&&".to_owned(),
            "java".to_owned(),
            "Main".to_owned(),
        ]
    );
}

#[test]
fn builtin_runner_is_used_when_config_has_no_runner() {
    let config = ConfigState::default();
    let resolved = resolve_runner(&config, "/tmp/main.py", "python", None, None)
        .expect("builtin runner resolves");

    assert_eq!(resolved.source, RunnerSource::Builtin);
    assert_eq!(
        resolved.command.as_deref(),
        Some("python3 -u '/tmp/main.py'")
    );
}

#[test]
fn argv_runner_preserves_arguments_without_shell_retokenizing() {
    let mut runner = ResolvedRunner {
        source: RunnerSource::Config,
        filetype: "rust".to_owned(),
        command: None,
        argv: vec!["cargo".to_owned(), "run".to_owned(), "$file".to_owned()],
        ..ResolvedRunner::default()
    };

    materialize_runner(&mut runner, "/tmp/example dir/main.rs").expect("argv materializes");

    assert_eq!(
        runner.argv,
        vec![
            "cargo".to_owned(),
            "run".to_owned(),
            "/tmp/example dir/main.rs".to_owned()
        ]
    );
    assert!(runner.command.is_none());
}

#[test]
fn missing_executable_is_reported_without_invalidating_the_runner() {
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        1,
        r#"{"runners":{"text":"zignite_missing_runtime_tool $file"}}"#,
    )
    .expect("config applies");

    let resolved =
        resolve_runner(&config, "/tmp/main.txt", "text", None, None).expect("runner resolves");

    assert_eq!(
        resolved.missing_tool.as_deref(),
        Some("zignite_missing_runtime_tool")
    );
}

#[test]
fn inline_source_uses_a_stable_extension_path() {
    let config = ConfigState::default();
    let resolved = resolve_runner(&config, "", "zig", Some("pub fn main() void {}"), None)
        .expect("inline runner resolves");

    assert_eq!(
        resolved.execution_path.as_deref(),
        Some("zignite-inline.zig")
    );
    assert_eq!(resolved.source, RunnerSource::Builtin);
}

#[test]
fn zig_project_manifest_selects_project_run_command() {
    let root = std::env::temp_dir().join(format!("zignite-runtime-{}", std::process::id()));
    fs::create_dir_all(&root).expect("create runtime fixture");
    fs::write(root.join("build.zig"), "pub fn build(_: anytype) void {}\n")
        .expect("write build manifest");
    let source = root.join("main.zig");

    let resolved = resolve_runner(
        &ConfigState::default(),
        &source.to_string_lossy(),
        "zig",
        None,
        Some(&source.to_string_lossy()),
    )
    .expect("project runner resolves");

    assert_eq!(resolved.source, RunnerSource::Project);
    assert_eq!(resolved.command.as_deref(), Some("zig build run"));
    assert_eq!(
        resolved.cwd.as_deref(),
        Some(root.to_string_lossy().as_ref())
    );
    fs::remove_dir_all(root).expect("remove runtime fixture");
}

#[test]
fn zig_classifier_ignores_fake_declarations_in_comments_and_strings() {
    let source = r#"
        // fn main() void {}
        const text = "test { return; }";
        pub fn real() void {}
    "#;

    assert!(!zig_classifier::contains_main_function(source));
    assert!(!zig_classifier::contains_test_declaration(source));
    assert!(zig_classifier::contains_function(source, "real"));
}

#[test]
fn run_frame_returns_json_and_legacy_runner_records() {
    let mut reader =
        Cursor::new(b"\t--path=/tmp/main.py\n\t--filetype=python\n@@ZRUN_REQ_END 7\n".to_vec());
    let mut output = Vec::new();
    let config = ConfigState::default();

    handle_run_frame(
        &mut reader,
        &mut output,
        "@@ZRUN_REQ_BEGIN 7 --run-resolve",
        &config,
    )
    .expect("run frame resolves");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("RESULT_JSON\t"));
    assert!(response.contains("\tOK\t1\n"));
    assert!(response.contains("\tFILETYPE\tpython\n"));
    assert!(response.ends_with("@@ZRUN_RES_END 7\n"));

    let json_line = response
        .lines()
        .find_map(|line| line.strip_prefix("\tRESULT_JSON\t"))
        .expect("JSON response exists");
    let json: serde_json::Value = serde_json::from_str(json_line).expect("JSON is valid");
    let system_argv = json["system_argv"]
        .as_array()
        .expect("system argv is an array");
    assert_eq!(system_argv.len(), 2);
    assert_eq!(system_argv[1], "python3 -u '/tmp/main.py'");
}

#[test]
fn run_frame_rejects_eof_without_end_marker() {
    let mut reader = Cursor::new(b"\t--path=/tmp/main.py\n\t--filetype=python\n".to_vec());
    let mut output = Vec::new();
    let config = ConfigState::default();

    handle_run_frame(
        &mut reader,
        &mut output,
        "@@ZRUN_REQ_BEGIN 8 --run-resolve",
        &config,
    )
    .expect("malformed frame should return a structured error");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("@@ZRUN_RES_ERR 8 InvalidRunResolvePayload"));
}
