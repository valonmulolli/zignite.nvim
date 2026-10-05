use std::fs;
use std::io::Cursor;

use zignite::project::{handle_frame, run_daemon};

#[test]
fn project_frame_returns_tab_prefixed_commands() {
    let root =
        std::env::temp_dir().join(format!("zignite-project-protocol-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project");
    fs::write(root.join("Makefile"), "build:\n\t@true\n").expect("write makefile");
    let header = format!(
        "\t--kind=make\n\t--path={}\n@@ZPRJ_REQ_END 4\n",
        root.join("Makefile").display()
    );
    let mut reader = Cursor::new(header.into_bytes());
    let mut output = Vec::new();

    handle_frame(&mut reader, &mut output, "@@ZPRJ_REQ_BEGIN 4").expect("frame succeeds");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("\tCOMMAND\tbuild\tmake build\n"));
    assert!(response.ends_with("@@ZPRJ_RES_END 4\n"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn project_frame_reports_malformed_headers_and_eof() {
    let mut reader = Cursor::new(b"@@ZPRJ_REQ_END 7\n".to_vec());
    let mut output = Vec::new();
    handle_frame(&mut reader, &mut output, "@@ZPRJ_REQ_BEGIN 7 extra")
        .expect("malformed header gets a response");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("@@ZPRJ_RES_ERR 7 InvalidProjectDaemonHeader"));

    let mut reader = Cursor::new(Vec::new());
    let mut output = Vec::new();
    handle_frame(&mut reader, &mut output, "@@ZPRJ_REQ_BEGIN 8")
        .expect("truncated frame gets a response");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("@@ZPRJ_RES_ERR 8 UnexpectedEof"));
}

#[test]
fn shared_daemon_dispatches_project_frames() {
    let root = std::env::temp_dir().join(format!("zignite-project-daemon-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project");
    fs::write(
        root.join("package.json"),
        r#"{"scripts":{"test":"echo ok"}}"#,
    )
    .expect("write package json");
    let input = format!(
        "@@ZPRJ_REQ_BEGIN 9\n\t--kind=package-json\n\t--path={}\n@@ZPRJ_REQ_END 9\n",
        root.join("package.json").display()
    );
    let mut reader = Cursor::new(input.into_bytes());
    let mut output = Vec::new();
    let mut state = zignite::daemon::DaemonState::default();
    zignite::daemon::run_daemon(&mut reader, &mut output, &mut state)
        .expect("shared daemon dispatches project request");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("\tCOMMAND\ttest\tnpm test\n"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn project_values_with_protocol_text_stay_inside_body() {
    let root = std::env::temp_dir().join("zignite-@@ZPRJ_RES_END-10");
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project");
    fs::write(root.join("Makefile"), "build:\n\t@true\n").expect("write makefile");
    let input = format!(
        "@@ZPRJ_REQ_BEGIN 10\n\t--kind=make\n\t--path={}\n@@ZPRJ_REQ_END 10\n",
        root.join("Makefile").display()
    );
    let mut reader = Cursor::new(input.into_bytes());
    let mut output = Vec::new();
    run_daemon(&mut reader, &mut output).expect("project daemon succeeds");
    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("\tROOT\t"));
    assert!(response.ends_with("@@ZPRJ_RES_END 10\n"));
    let _ = fs::remove_dir_all(root);
}
