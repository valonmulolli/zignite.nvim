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
