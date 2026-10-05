use std::fs;

use zignite::build::{resolve_action, ActionKind, BuildState};
use zignite::config::{apply_config_sync, ConfigState};

fn root(name: &str) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("zignite-action-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project root");
    root
}

#[test]
fn named_action_materializes_command_and_records_last_command() {
    let root = root("named");
    let path = root.join("Cargo.toml");
    fs::write(
        &path,
        "[package]\nname = \"zignite-action-test\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
    )
    .expect("write manifest");
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        4,
        r#"{"build_commands":{"rust":{"metadata":"cargo metadata --manifest-path $file --no-deps"}}}"#,
    )
    .expect("sync config");
    let mut state = BuildState::default();

    let plan = resolve_action(
        &config,
        &mut state,
        &path,
        "rust",
        ActionKind::Named,
        Some("metadata"),
        None,
    )
    .expect("resolve named action");
    assert!(plan.ok);
    assert_eq!(plan.resolved_command_name.as_deref(), Some("metadata"));
    let canonical_root = fs::canonicalize(&root).expect("canonical root");
    assert_eq!(
        plan.cwd.as_deref(),
        Some(canonical_root.to_str().expect("utf8 root"))
    );
    assert_eq!(
        &plan.exec_argv[..3],
        ["cargo", "metadata", "--manifest-path"]
    );
    assert_eq!(
        fs::canonicalize(&plan.exec_argv[3]).expect("canonicalized command manifest"),
        fs::canonicalize(&path).expect("canonical manifest")
    );
    assert_eq!(plan.exec_argv[4], "--no-deps");

    let last = resolve_action(
        &config,
        &mut state,
        &path,
        "rust",
        ActionKind::Last,
        None,
        None,
    )
    .expect("resolve last action");
    assert!(last.ok);
    assert_eq!(last.resolved_command_name.as_deref(), Some("metadata"));

    let _ = fs::remove_dir_all(root);
}

#[test]
fn action_returns_argument_metadata_before_execution() {
    let root = root("arguments");
    let path = root.join("build.zig");
    fs::write(&path, "pub fn build(b: *std.Build) void { _ = b; }\n").expect("write source");
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        5,
        r#"{"build_commands":{"zig":{"fetch":"zig fetch $zignite_args"}}}"#,
    )
    .expect("sync config");

    let plan = resolve_action(
        &config,
        &mut BuildState::default(),
        &path,
        "zig",
        ActionKind::Named,
        Some("fetch"),
        None,
    )
    .expect("resolve argument action");
    assert!(!plan.ok);
    assert_eq!(plan.reason.as_deref(), Some("missing_arguments"));
    assert!(plan.requires_arguments);
    assert!(plan.argument_prompt.is_some());
    assert!(plan.argument_help.is_some());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn action_reports_missing_tool_without_running_it() {
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        6,
        r#"{"build_commands":{"text":{"build":"zignite-tool-that-does-not-exist build"}}}"#,
    )
    .expect("sync config");
    let plan = resolve_action(
        &config,
        &mut BuildState::default(),
        std::path::Path::new("main.txt"),
        "text",
        ActionKind::Named,
        Some("build"),
        None,
    )
    .expect("resolve missing tool");
    assert!(!plan.ok);
    assert_eq!(plan.reason.as_deref(), Some("missing_tool"));
    assert_eq!(
        plan.missing_tool.as_deref(),
        Some("zignite-tool-that-does-not-exist")
    );
}

#[test]
fn action_checks_relative_tools_from_the_project_directory() {
    let root = root("relative-tool");
    let path = root.join("main.txt");
    fs::write(&path, "input\n").expect("write source");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let wrapper = root.join("tool");
        fs::write(&wrapper, "#!/bin/sh\nprintf 'tool 1.0\\n'\n").expect("write tool");
        let mut permissions = fs::metadata(&wrapper).expect("tool metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&wrapper, permissions).expect("make tool executable");
    }

    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        8,
        r#"{"build_commands":{"text":{"build":"./tool build"}}}"#,
    )
    .expect("sync config");
    let plan = resolve_action(
        &config,
        &mut BuildState::default(),
        &path,
        "text",
        ActionKind::Named,
        Some("build"),
        None,
    )
    .expect("resolve relative tool");

    #[cfg(unix)]
    assert!(plan.ok);
    #[cfg(windows)]
    assert_eq!(plan.reason.as_deref(), Some("missing_tool"));
    let _ = fs::remove_dir_all(root);
}
