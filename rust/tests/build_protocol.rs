use std::fs;
use std::io::Cursor;

use zignite::build::{handle_action_frame, handle_resolve_frame};
use zignite::config::ConfigState;

#[test]
fn resolve_frame_returns_json_inside_a_response_frame() {
    let root = std::env::temp_dir().join(format!("zignite-build-protocol-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project root");
    fs::write(root.join("Makefile"), "build:\n\t@true\n").expect("write makefile");
    let input = format!(
        "\t--path={}\n\t--filetype=cpp\n@@ZBR_REQ_END 12\n",
        root.join("main.cpp").display()
    );
    let mut reader = Cursor::new(input.into_bytes());
    let mut output = Vec::new();
    let mut state = zignite::build::BuildState::default();
    handle_resolve_frame(
        &mut reader,
        &mut output,
        "@@ZBR_REQ_BEGIN 12",
        &ConfigState::default(),
        &mut state,
    )
    .expect("resolve frame succeeds");
    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("RESULT_JSON\t"));
    assert!(response.contains("\"name\":\"build\""));
    assert!(response.ends_with("@@ZBR_RES_END 12\n"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn malformed_action_header_is_recovered_without_losing_the_frame() {
    let mut reader = Cursor::new(b"@@ZBA_REQ_END 13\n".to_vec());
    let mut output = Vec::new();
    let mut state = zignite::build::BuildState::default();
    handle_action_frame(
        &mut reader,
        &mut output,
        "@@ZBA_REQ_BEGIN 13 extra",
        &ConfigState::default(),
        &mut state,
    )
    .expect("malformed frame gets an error response");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("@@ZBA_RES_ERR 13 InvalidBuildActionDaemonHeader"));
}

#[test]
fn shared_daemon_keeps_last_build_command_between_action_and_resolve() {
    let root = std::env::temp_dir().join(format!("zignite-daemon-build-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project root");
    let path = root.join("main.txt").display().to_string();
    let configuration = r#"{"build_commands":{"text":{"build":"cargo build"}}}"#;
    let input = format!(
        "@@ZCFG_REQ_BEGIN 20 1\n\t{configuration}\n@@ZCFG_REQ_END 20\n\
         @@ZBA_REQ_BEGIN 21\n\t--path={path}\n\t--filetype=text\n\
         \t--action=named\n\t--command-name=build\n@@ZBA_REQ_END 21\n\
         @@ZBR_REQ_BEGIN 22\n\t--path={path}\n\t--filetype=text\n\
         @@ZBR_REQ_END 22\n"
    );
    let mut reader = Cursor::new(input.as_bytes());
    let mut output = Vec::new();
    let mut state = zignite::daemon::DaemonState::default();
    zignite::daemon::run_daemon(&mut reader, &mut output, &mut state)
        .expect("shared daemon processes build frames");
    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("@@ZBA_RES_END 21\n"));
    assert!(response.contains("\"last_command_name\":\"build\""));
    assert!(response.contains("@@ZBR_RES_END 22\n"));
    let _ = fs::remove_dir_all(root);
}
