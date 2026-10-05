#![cfg(unix)]

use std::fs;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use zignite::process::{run_argv, CommandSpec, TimeoutPolicy};

#[test]
fn timeout_kills_descendants_in_the_process_group() {
    let marker = std::env::temp_dir().join(format!(
        "zignite-descendant-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos()
    ));
    let marker_text = marker.to_string_lossy().into_owned();
    let script = format!("(sleep .2; printf survived > '{}') & wait", marker_text);
    let spec = CommandSpec {
        argv: vec!["sh".into(), "-c".into(), script.into()],
        cwd: None,
        env: Vec::new(),
    };

    let result = run_argv(
        &spec,
        TimeoutPolicy {
            timeout: Some(Duration::from_millis(50)),
            grace: Duration::from_millis(50),
        },
        None,
    )
    .expect("timed out process should return");

    std::thread::sleep(Duration::from_millis(300));
    assert!(result.timed_out);
    assert!(!marker.exists(), "descendant survived timeout");
    let _ = fs::remove_file(marker);
}
