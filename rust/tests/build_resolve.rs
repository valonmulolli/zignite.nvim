use std::fs;

use zignite::build::{resolve_build, BuildSource};
use zignite::config::{apply_config_sync, ConfigState};

fn project_root(name: &str) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("zignite-build-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project root");
    root
}

#[test]
fn resolve_build_merges_config_project_and_builtin_commands() {
    let root = project_root("merge");
    fs::write(
        root.join("Makefile"),
        "build:\n\t@true\nrun:\n\t@true\nverify:\n\t@true\n",
    )
    .expect("write makefile");
    fs::write(root.join("main.cpp"), "int main() {}\n").expect("write source");

    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        7,
        r#"{"build_commands":{"cpp":{"custom":"make custom","build":"make configured-build"}}}"#,
    )
    .expect("sync config");

    let output = resolve_build(&config, &root.join("main.cpp"), "cpp", None)
        .expect("resolve build commands");
    assert_eq!(output.filetype, "cpp");
    let canonical_root = fs::canonicalize(&root).expect("canonical root");
    assert_eq!(
        output.root.as_deref(),
        Some(canonical_root.to_str().expect("utf8 root"))
    );
    assert_eq!(output.system.as_deref(), Some("make"));
    assert_eq!(output.config_revision, 7);
    assert_eq!(
        output.command("build").expect("build command").command,
        "make configured-build"
    );
    assert_eq!(
        output.command("custom").expect("custom command").source,
        BuildSource::Config
    );
    assert_eq!(
        output.command("run").expect("run command").command,
        "make run"
    );
    assert!(output.command("verify").is_some());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn resolve_build_does_not_invent_zig_build_steps_without_a_build_file() {
    let root = project_root("builtin");
    let path = root.join("main.zig");
    fs::write(&path, "pub fn main() void {}\n").expect("write source");

    let output = resolve_build(&ConfigState::default(), &path, "zig", None)
        .expect("resolve builtin commands");
    assert!(output.command("build").is_none());
    assert!(output.command("run").is_none());
    assert!(output.command("test").is_none());
    assert!(output.command("check").is_none());
    assert_eq!(
        output.command("fetch").expect("fetch command").command,
        "zig fetch $zignite_args"
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn build_detection_toggle_disables_matching_project_system() {
    let root = project_root("disabled-go-detection");
    let path = root.join("main.go");
    fs::write(&path, "package main\n").expect("write source");
    fs::write(root.join("go.mod"), "module example.com/demo\n").expect("write module");

    let mut config = ConfigState::default();
    apply_config_sync(&mut config, 1, r#"{"detect":{"go":false}}"#).expect("sync config");

    let output = resolve_build(&config, &path, "go", None).expect("resolve Go commands");
    assert_ne!(output.system.as_deref(), Some("go"));
    assert!(output
        .commands
        .iter()
        .all(|command| command.source != BuildSource::Project));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn resolve_build_rejects_unsafe_config_payloads() {
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        9,
        "{\"build_commands\":{\"go\":{\"bad\\nname\":\"go test\"}}}",
    )
    .expect("sync config");

    let output = resolve_build(&config, std::path::Path::new("main.go"), "go", None)
        .expect("resolve without unsafe command");
    assert!(output.command("bad\nname").is_none());
}

#[test]
fn configured_filetype_wins_over_a_different_source_extension() {
    let root = project_root("configured-filetype");
    let path = root.join("main.cpp");
    fs::write(&path, "int main() {}\n").expect("write source");
    let mut config = ConfigState::default();
    apply_config_sync(
        &mut config,
        10,
        r#"{"build_commands":{"c":{"custom":"make custom"}}}"#,
    )
    .expect("sync config");

    let output = resolve_build(&config, &path, "c", None).expect("resolve configured filetype");
    assert_eq!(output.filetype, "c");
    assert!(output.command("custom").is_some());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn c_family_without_a_project_does_not_invent_make_commands() {
    let root = project_root("no-c-project");
    let path = root.join("main.cpp");
    fs::write(&path, "int main() {}\n").expect("write source");

    let output = resolve_build(&ConfigState::default(), &path, "cpp", None)
        .expect("resolve source without project");
    assert!(!output.ok);
    assert!(output.commands.is_empty());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn go_resolution_merges_make_targets_with_go_defaults() {
    let root = project_root("go-make");
    let path = root.join("main.go");
    fs::write(&path, "package main\n").expect("write source");
    fs::write(root.join("go.mod"), "module example.com/demo\n").expect("write module");
    fs::write(
        root.join("Makefile"),
        ".PHONY: build run test fmt\nbuild:\n\t@true\nrun:\n\t@true\ntest:\n\t@true\nfmt:\n\t@true\n",
    )
    .expect("write makefile");

    let output =
        resolve_build(&ConfigState::default(), &path, "go", None).expect("resolve go project");
    assert_eq!(output.system.as_deref(), Some("make"));
    assert_eq!(
        output.command("build").expect("make build").command,
        "make build"
    );
    assert_eq!(output.command("run").expect("make run").command, "make run");
    assert_eq!(
        output.command("mod").expect("go mod").command,
        "go mod tidy"
    );
    assert!(output.command("fmt").is_some());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn package_dev_script_gets_live_picker_alias() {
    let root = project_root("package-live");
    let path = root.join("src/main.ts");
    fs::create_dir_all(root.join("src")).expect("create source directory");
    fs::write(&path, "export {};\n").expect("write source");
    fs::write(
        root.join("package.json"),
        r#"{"scripts":{"dev":"vite","build":"vite build"}}"#,
    )
    .expect("write package json");

    let output = resolve_build(&ConfigState::default(), &path, "typescript", None)
        .expect("resolve package project");
    assert_eq!(
        output.command("live").expect("live alias").command,
        "npm run dev"
    );
    assert_eq!(output.live_preferred_name.as_deref(), Some("live"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn cmake_resolution_keeps_baseline_commands_and_target_override() {
    let root = project_root("cmake-defaults");
    let path = root.join("src/main.cpp");
    fs::create_dir_all(root.join("src")).expect("create source directory");
    fs::write(&path, "int main() {}\n").expect("write source");
    fs::write(
        root.join("CMakeLists.txt"),
        "project(demo)\nadd_executable(demo src/main.cpp)\n",
    )
    .expect("write cmake project");

    let output =
        resolve_build(&ConfigState::default(), &path, "cpp", None).expect("resolve cmake project");
    assert_eq!(output.system.as_deref(), Some("cmake"));
    assert_eq!(output.build_ready, Some(false));
    assert_eq!(
        output.command("build").expect("target build").command,
        "cmake --build build --target demo"
    );
    assert!(output.command("cmake-config").is_some());
    assert!(output.command("cmake-test").is_some());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn bazel_resolution_keeps_workspace_baseline_and_targets() {
    let root = project_root("bazel-defaults");
    let path = root.join("app/main.cc");
    fs::create_dir_all(root.join("app")).expect("create app directory");
    fs::write(&path, "int main() {}\n").expect("write source");
    fs::write(root.join("MODULE.bazel"), "").expect("write module");
    fs::write(
        root.join("app/BUILD.bazel"),
        "cc_binary(name = \"main\", srcs = [\"main.cc\"])\n",
    )
    .expect("write build file");

    let output =
        resolve_build(&ConfigState::default(), &path, "cpp", None).expect("resolve bazel project");
    assert_eq!(output.system.as_deref(), Some("bazel"));
    assert_eq!(
        output.command("build").expect("bazel build").command,
        "bazel build //..."
    );
    assert_eq!(
        output.command("build-main").expect("target build").command,
        "bazel build //app:main"
    );
    let _ = fs::remove_dir_all(root);
}
