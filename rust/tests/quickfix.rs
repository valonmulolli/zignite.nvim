use zignite::quickfix::{
    parse_diagnostic, process_quickfix, strip_ansi, tail_output, QuickfixOptions,
};

#[test]
fn strip_ansi_removes_csi_osc_and_preserves_utf8() {
    let input = "\x1b[31merror\x1b[0m \x1b]0;title\x07✓".as_bytes();

    assert_eq!(strip_ansi(input), "error ✓".as_bytes());
}

#[test]
fn unterminated_escape_consumes_only_the_sequence() {
    assert_eq!(strip_ansi(b"before\x1b[31"), b"before");
    assert_eq!(strip_ansi(b"a\x1bb"), b"a\x1bb");
}

#[test]
fn diagnostics_cover_zig_rust_go_gcc_and_clang_shapes() {
    assert_eq!(
        parse_diagnostic(b"--> src/main.zig:12:4: unexpected token"),
        Some("src/main.zig:12:4: unexpected token".to_owned())
    );
    assert_eq!(
        parse_diagnostic(b"src/main.rs:7:2: error: missing ;"),
        Some("src/main.rs:7:2: error: missing ;".to_owned())
    );
    assert_eq!(
        parse_diagnostic(b"main.go:3:9: undefined: value"),
        Some("main.go:3:9: undefined: value".to_owned())
    );
    assert_eq!(
        parse_diagnostic(b"src/main.c:8: warning: unused variable"),
        Some("src/main.c:8:1: warning: unused variable".to_owned())
    );
    assert_eq!(
        parse_diagnostic(b"src/main.cpp(17:3) error C2065: undeclared"),
        Some("src/main.cpp:17:3: error C2065: undeclared".to_owned())
    );
}

#[test]
fn malformed_and_plain_lines_are_not_diagnostics() {
    assert_eq!(parse_diagnostic(b"error: file not found"), None);
    assert_eq!(parse_diagnostic(b"Compiling project..."), None);
    assert_eq!(parse_diagnostic(b"src/main.rs:not-a-line: error"), None);
}

#[test]
fn tail_keeps_newest_complete_lines_and_handles_crlf() {
    let result = tail_output(b"old\r\nmiddle\nnewest\n", 14);

    assert_eq!(result.lines, vec![b"middle".to_vec(), b"newest".to_vec()]);
    assert!(result.truncated);
}

#[test]
fn tail_limits_lines_without_underflow() {
    let result = tail_output(b"a\nb\nc\n", usize::MAX);

    assert_eq!(
        result.lines,
        vec![b"a".to_vec(), b"b".to_vec(), b"c".to_vec()]
    );
    assert!(!result.truncated);
}

#[test]
fn quickfix_pipeline_applies_limits_strip_and_diagnostic_normalization() {
    let result = process_quickfix(
        b"old\n\x1b[31m--> src/main.zig:12:4: bad\x1b[0m\nplain\n",
        QuickfixOptions {
            max_lines: 2,
            max_bytes: 1024,
            strip_ansi: true,
            strip_max_lines: 2,
            parse_diagnostics: true,
        },
        false,
    );

    assert_eq!(
        result.lines,
        vec![
            "[zignite] quickfix output truncated".to_owned(),
            "src/main.zig:12:4: bad".to_owned(),
            "plain".to_owned(),
        ]
    );
    assert!(result.truncated);
}

#[test]
fn quickfix_preserves_empty_input_and_invalid_utf8_without_panicking() {
    let empty = process_quickfix(b"", QuickfixOptions::default(), false);
    assert!(empty.lines.is_empty());
    assert!(!empty.truncated);

    let invalid = process_quickfix(b"bad \xff\n", QuickfixOptions::default(), false);
    assert_eq!(invalid.lines, vec!["bad �".to_owned()]);
}

#[test]
fn quickfix_line_limits_larger_than_input_do_not_underflow() {
    let result = process_quickfix(
        b"one\ntwo\n",
        QuickfixOptions {
            max_lines: usize::MAX,
            max_bytes: usize::MAX,
            strip_ansi: true,
            strip_max_lines: usize::MAX,
            parse_diagnostics: false,
        },
        false,
    );

    assert_eq!(result.lines, vec!["one", "two"]);
    assert!(!result.truncated);
}
