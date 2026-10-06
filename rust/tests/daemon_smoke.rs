use std::io::Cursor;

use zignite::daemon::{run_daemon, DaemonState};

#[test]
fn daemon_answers_health_request_before_eof() {
    let mut input = Cursor::new(b"@@ZHLT_REQ_BEGIN 1\n".to_vec());
    let mut output = Vec::new();
    let mut state = DaemonState::default();

    run_daemon(&mut input, &mut output, &mut state).expect("health request should succeed");

    assert_eq!(
        String::from_utf8(output).expect("response is utf8"),
        "@@ZHLT_RES_BEGIN 1\n@@ZHLT_RES_END 1\n"
    );
}

#[test]
fn daemon_skips_tool_detection_when_disabled_in_config() {
    let input = b"@@ZCFG_REQ_BEGIN 1 1\n\t{\"detect\":{\"zig\":false}}\n@@ZCFG_REQ_END 1\n@@ZDET_REQ_BEGIN 2 zig\n@@ZDET_REQ_END 2\n";
    let mut reader = Cursor::new(input.to_vec());
    let mut output = Vec::new();
    let mut state = DaemonState::default();

    run_daemon(&mut reader, &mut output, &mut state)
        .expect("daemon should honor disabled Zig detection");

    let response = String::from_utf8(output).expect("response is UTF-8");
    assert!(response.contains("@@ZCFG_RES_END 1"));
    assert!(response.contains("@@ZDET_RES_BEGIN 2\n@@ZDET_RES_END 2\n"));
    assert!(!response.contains("zig build"));
}
