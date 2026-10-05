use std::time::Duration;

use zignite::config::{
    apply_config_sync, validate_config, BuildCommand, ConfigError, ConfigState, RunnerConfig,
};

const VALID_CONFIG: &str = r#"{
  "runners": {
    "go": "go run $file",
    "rust": ["cargo", "run"],
    "zig": {"cmd": ["zig", "run", "$file"], "cleanup_command": "rm -f /tmp/out", "cwd": "/tmp"}
  },
  "build_commands": {"zig": {"build": "zig build", "test": "zig build test"}},
  "detect": {"zig": false},
  "timeout": 1200,
  "project": {"/tmp/demo": {"name": "Demo", "command": "cargo run"}}
}"#;

#[test]
fn valid_config_is_stored_and_exposed_as_typed_records() {
    let mut state = ConfigState::default();
    let warnings = apply_config_sync(&mut state, 1, VALID_CONFIG).expect("config is valid");

    assert!(warnings.is_empty());
    assert_eq!(state.revision(), 1);
    assert_eq!(state.execution_timeout(), Some(Duration::from_millis(1200)));
    assert_eq!(state.detect_enabled("zig"), Some(false));
    assert_eq!(
        state.runner_config("go"),
        Some(RunnerConfig::Command("go run $file".to_owned()))
    );
    assert_eq!(
        state.runner_config("rust"),
        Some(RunnerConfig::Argv(vec![
            "cargo".to_owned(),
            "run".to_owned()
        ]))
    );
    assert_eq!(
        state.build_commands("zig"),
        vec![
            BuildCommand {
                name: "build".to_owned(),
                command: "zig build".to_owned()
            },
            BuildCommand {
                name: "test".to_owned(),
                command: "zig build test".to_owned()
            }
        ]
    );
}

#[test]
fn object_runner_preserves_cleanup_and_cwd_metadata() {
    let warnings = validate_config(VALID_CONFIG).expect("JSON is valid");
    assert!(warnings.is_empty());

    let mut state = ConfigState::default();
    apply_config_sync(&mut state, 1, VALID_CONFIG).expect("config applies");

    assert_eq!(
        state.runner_config("zig"),
        Some(RunnerConfig::Object {
            command: vec!["zig".to_owned(), "run".to_owned(), "$file".to_owned()],
            cleanup_command: Some("rm -f /tmp/out".to_owned()),
            cwd: Some("/tmp".to_owned()),
        })
    );
}

#[test]
fn same_revision_is_idempotent_but_older_revision_is_rejected() {
    let mut state = ConfigState::default();
    apply_config_sync(&mut state, 4, "{}").expect("first revision applies");
    apply_config_sync(&mut state, 4, "{}").expect("same revision can be re-synced");

    assert!(matches!(
        apply_config_sync(&mut state, 3, "{}"),
        Err(ConfigError::StaleRevision {
            current: 4,
            incoming: 3
        })
    ));
}

#[test]
fn invalid_timeout_and_detect_values_return_warnings() {
    let warnings =
        validate_config(r#"{"timeout":0,"detect":{"zig":"yes"}}"#).expect("JSON is valid");

    assert!(warnings
        .iter()
        .any(|warning| warning.contains("Invalid config timeout")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("Invalid config detect.zig")));
}

#[test]
fn control_characters_in_commands_return_warnings() {
    let warnings = validate_config(r#"{"build_commands":{"zig":{"build":"zig\nrun"}}}"#)
        .expect("JSON is valid");

    assert!(warnings
        .iter()
        .any(|warning| warning.contains("build_commands.zig.build")));
}

#[test]
fn malformed_json_and_non_object_root_are_errors() {
    assert!(matches!(
        validate_config("{"),
        Err(ConfigError::InvalidJson)
    ));
    assert!(matches!(
        validate_config("[]"),
        Err(ConfigError::InvalidRoot)
    ));
}

#[test]
fn invalid_project_shape_returns_warnings() {
    let warnings = validate_config(
        r#"{"project":{"/tmp/missing":{},"/tmp/wrong":"cargo run","/tmp/good":{"command":"cargo run","name":3}}}"#,
    )
    .expect("JSON is valid");

    assert!(warnings
        .iter()
        .any(|warning| warning.contains("missing command")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("expected object")));
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("project./tmp/good.name")));
}
