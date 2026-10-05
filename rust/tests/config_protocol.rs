use std::io::Cursor;

use zignite::config::{apply_config_sync, handle_config_frame, ConfigState};

#[test]
fn config_sync_returns_revision_and_warning_records() {
    let mut state = ConfigState::default();
    let warnings = apply_config_sync(
        &mut state,
        19,
        r#"{"detect":{"zig":"yes"},"timeout":"slow"}"#,
    )
    .expect("valid JSON should be accepted with warnings");

    assert_eq!(state.revision(), 19);
    assert!(warnings
        .iter()
        .any(|warning| warning.contains("detect.zig")));
    assert!(warnings.iter().any(|warning| warning.contains("timeout")));
}

#[test]
fn config_frame_collects_body_and_writes_revision_response() {
    let mut reader = Cursor::new(b"\t{\"timeout\":1200}\n@@ZCFG_REQ_END 3\n".to_vec());
    let mut output = Vec::new();
    let mut state = ConfigState::default();

    handle_config_frame(
        &mut reader,
        &mut output,
        "@@ZCFG_REQ_BEGIN 3 19",
        &mut state,
    )
    .expect("config frame should succeed");

    assert_eq!(state.revision(), 19);
    assert_eq!(
        String::from_utf8(output).expect("response is utf8"),
        "@@ZCFG_RES_BEGIN 3\n\tREVISION\t19\n@@ZCFG_RES_END 3\n"
    );
}
