use std::io::Cursor;

use zignite::protocol::{
    has_marker_prefix, parse_request_id, read_line_limited, write_response, ProtocolError,
    RequestId, ResponseFrame,
};

#[test]
fn read_line_limited_strips_crlf() {
    let mut reader = Cursor::new(b"hello\r\nworld\n".to_vec());

    assert_eq!(
        read_line_limited(&mut reader, 16).expect("first line"),
        Some("hello".to_owned())
    );
    assert_eq!(
        read_line_limited(&mut reader, 16).expect("second line"),
        Some("world".to_owned())
    );
}

#[test]
fn read_line_limited_rejects_oversized_lines() {
    let mut reader = Cursor::new(b"12345\n".to_vec());

    assert!(matches!(
        read_line_limited(&mut reader, 4),
        Err(ProtocolError::LineTooLong { limit: 4 })
    ));
}

#[test]
fn marker_matching_rejects_marker_name_prefixes() {
    assert!(has_marker_prefix("@@ZHLT_REQ_BEGIN 7", "@@ZHLT_REQ_BEGIN"));
    assert!(has_marker_prefix("@@ZHLT_REQ_BEGIN\t7", "@@ZHLT_REQ_BEGIN"));
    assert!(has_marker_prefix("@@ZHLT_REQ_BEGIN", "@@ZHLT_REQ_BEGIN"));
    assert!(!has_marker_prefix(
        "@@ZHLT_REQ_BEGINNING 7",
        "@@ZHLT_REQ_BEGIN"
    ));
}

#[test]
fn request_id_requires_a_numeric_marker_argument() {
    assert_eq!(
        parse_request_id("@@ZQF_BEGIN 42 100 2048", "@@ZQF_BEGIN"),
        Some(RequestId(42))
    );
    assert_eq!(
        parse_request_id("@@ZQF_BEGIN nope 100", "@@ZQF_BEGIN"),
        None
    );
    assert_eq!(
        parse_request_id("@@ZDET_REQ_BEGIN 42 cargo", "@@ZQF_BEGIN"),
        None
    );
}

#[test]
fn response_writer_tab_prefixes_body_and_flushes() {
    let body = vec!["COMMAND\tunsafe".to_owned(), "@@ZPRJ_RES_END 7".to_owned()];
    let response =
        ResponseFrame::success("@@ZPRJ_RES_BEGIN", "@@ZPRJ_RES_END", RequestId(7), &body);
    let mut output = Vec::new();

    write_response(&mut output, response).expect("response should be valid");

    assert_eq!(
        String::from_utf8(output).expect("response is utf8"),
        "@@ZPRJ_RES_BEGIN 7\n\tCOMMAND\tunsafe\n\t@@ZPRJ_RES_END 7\n@@ZPRJ_RES_END 7\n"
    );
}

#[test]
fn response_writer_rejects_control_characters() {
    let body = vec!["COMMAND\tbad\nvalue".to_owned()];
    let response =
        ResponseFrame::success("@@ZPRJ_RES_BEGIN", "@@ZPRJ_RES_END", RequestId(7), &body);
    let mut output = Vec::new();

    assert!(matches!(
        write_response(&mut output, response),
        Err(ProtocolError::ControlCharacter)
    ));
}

#[test]
fn malformed_response_marker_is_rejected() {
    let response = ResponseFrame::success(
        "@@ZPRJ_RES_BEGIN\ninvalid",
        "@@ZPRJ_RES_END",
        RequestId(7),
        &[],
    );
    let mut output = Vec::new();

    assert!(matches!(
        write_response(&mut output, response),
        Err(ProtocolError::InvalidMarker)
    ));
}
