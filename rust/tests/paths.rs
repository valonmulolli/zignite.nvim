use zignite::filetype::filetype_from_path;
use zignite::paths::{normalize_path, quote_shell_arg};

#[test]
fn normalize_path_removes_dot_segments_without_changing_root() {
    assert_eq!(
        normalize_path("/tmp/./project/../main.zig"),
        "/tmp/main.zig"
    );
    assert_eq!(normalize_path("src/./main.go"), "src/main.go");
}

#[test]
fn normalize_path_handles_windows_drive_and_unc_paths() {
    assert_eq!(
        normalize_path(r"C:\work\project\..\main.zig"),
        r"C:\work\main.zig"
    );
    assert_eq!(
        normalize_path(r"\\server\share\project\..\main.zig"),
        r"\\server\share\main.zig"
    );
}

#[test]
fn filetype_policy_applies_aliases_and_manifest_names() {
    assert_eq!(filetype_from_path("c++", "/tmp/main.cpp"), "cpp");
    assert_eq!(
        filetype_from_path("json", "/tmp/package.json"),
        "javascript"
    );
    assert_eq!(filetype_from_path("toml", "/tmp/Cargo.toml"), "rust");
    assert_eq!(
        filetype_from_path("unknown", "/tmp/main.unknown"),
        "unknown"
    );
}

#[test]
fn shell_quoting_does_not_allow_spaces_to_split_a_path() {
    let expected = if cfg!(windows) {
        "\"/tmp/example dir/main.go\""
    } else {
        "'/tmp/example dir/main.go'"
    };
    assert_eq!(quote_shell_arg("/tmp/example dir/main.go"), expected);
}
