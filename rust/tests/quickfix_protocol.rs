use std::io::Cursor;

use zignite::quickfix::{handle_frame, QUICKFIX_RES_BEGIN, QUICKFIX_RES_END};

#[test]
fn quickfix_frame_returns_tab_prefixed_processed_lines() {
    let input = b"\t\x1b[31merror\x1b[0m\n\t@@ZQF_RES_END 7\n@@ZQF_END 7\n";
    let mut reader = Cursor::new(input.to_vec());
    let mut output = Vec::new();

    handle_frame(&mut reader, &mut output, "@@ZQF_BEGIN 7 10 1024 1 10 1")
        .expect("quickfix frame succeeds");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.starts_with(&format!("{QUICKFIX_RES_BEGIN} 7\n")));
    assert!(response.contains("\terror\n"));
    assert!(response.contains("\t@@ZQF_RES_END 7\n"));
    assert!(response.ends_with(&format!("{QUICKFIX_RES_END} 7\n")));
}

#[test]
fn quickfix_frame_reports_malformed_header_with_request_id() {
    let mut reader = Cursor::new(b"@@ZQF_END 9\n".to_vec());
    let mut output = Vec::new();

    handle_frame(&mut reader, &mut output, "@@ZQF_BEGIN 9 invalid")
        .expect("malformed frame returns a structured response");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("@@ZQF_RES_ERR 9 InvalidQuickfixHeader"));
    assert!(response.ends_with("@@ZQF_RES_END 9\n"));
}

#[test]
fn quickfix_frame_rejects_eof_without_end_marker() {
    let mut reader = Cursor::new(b"\tline\n".to_vec());
    let mut output = Vec::new();

    handle_frame(&mut reader, &mut output, "@@ZQF_BEGIN 11 10 1024 1 10 1")
        .expect("EOF returns a structured response");

    let response = String::from_utf8(output).expect("response is utf8");
    assert!(response.contains("@@ZQF_RES_ERR 11 UnexpectedEof"));
}
