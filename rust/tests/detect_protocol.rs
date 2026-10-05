use std::io::Cursor;

use zignite::detect::{handle_frame_with, DetectedCommand};

#[test]
fn detect_frame_returns_tab_prefixed_records() {
    let mut reader = Cursor::new(b"@@ZDET_REQ_END 5\n".to_vec());
    let mut output = Vec::new();

    handle_frame_with(
        &mut reader,
        &mut output,
        "@@ZDET_REQ_BEGIN 5 zig",
        |_tool| {
            Ok(vec![DetectedCommand {
                name: "build".to_owned(),
                command: "zig build".to_owned(),
            }])
        },
    )
    .expect("detect frame succeeds");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("\tbuild\tzig build\n"));
    assert!(response.ends_with("@@ZDET_RES_END 5\n"));
}

#[test]
fn detect_frame_preserves_marker_looking_command_as_body_data() {
    let mut reader = Cursor::new(b"@@ZDET_REQ_END 6\n".to_vec());
    let mut output = Vec::new();

    handle_frame_with(
        &mut reader,
        &mut output,
        "@@ZDET_REQ_BEGIN 6 zig",
        |_tool| {
            Ok(vec![DetectedCommand {
                name: "safe".to_owned(),
                command: "zig echo @@ZDET_RES_END 6".to_owned(),
            }])
        },
    )
    .expect("detect frame succeeds");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("\tsafe\tzig echo @@ZDET_RES_END 6\n"));
}

#[test]
fn detect_frame_reports_invalid_tool_and_eof() {
    let mut reader = Cursor::new(b"@@ZDET_REQ_END 7\n".to_vec());
    let mut output = Vec::new();
    handle_frame_with(
        &mut reader,
        &mut output,
        "@@ZDET_REQ_BEGIN 7 invalid",
        |_tool| unreachable!(),
    )
    .expect("invalid header returns a response");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("@@ZDET_RES_ERR 7 InvalidDetectTool"));

    let mut reader = Cursor::new(b"".to_vec());
    let mut output = Vec::new();
    handle_frame_with(
        &mut reader,
        &mut output,
        "@@ZDET_REQ_BEGIN 8 zig",
        |_tool| Ok(Vec::new()),
    )
    .expect("EOF returns a response");
    assert!(String::from_utf8(output)
        .expect("response is utf8")
        .contains("@@ZDET_RES_ERR 8 UnexpectedEof"));
}
