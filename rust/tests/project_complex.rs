use std::fs;
use std::path::{Path, PathBuf};

use zignite::project::{parse_project, parse_zig_steps, ProjectError, ProjectKind};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("test_fixtures")
        .join(name)
}

fn command(project: &zignite::project::Project, name: &str) -> String {
    project
        .commands
        .iter()
        .find(|command| command.name == name)
        .map(|command| command.command.clone())
        .unwrap_or_else(|| panic!("missing command {name}"))
}

#[test]
fn parses_cmake_target_with_quoted_comment_awareness() {
    let root = std::env::temp_dir().join(format!("zignite-cmake-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create cmake project");
    fs::write(
        root.join("CMakeLists.txt"),
        "set(note \"# add_executable(fake src/fake.cpp)\")\n# add_executable(comment src/comment.cpp)\nadd_executable(real src/main.cpp)\n",
    )
    .expect("write cmake project");

    let project = parse_project(ProjectKind::CMake, &root, Some(&root.join("src/main.cpp")))
        .expect("cmake project parses");
    assert_eq!(
        command(&project, "build"),
        "cmake --build build --target real"
    );
    assert!(project.commands.iter().all(|item| item.name != "fake"));
    assert!(project.commands.iter().all(|item| item.name != "comment"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn parses_meson_fixture_target() {
    let project = parse_project(
        ProjectKind::Meson,
        &fixture("meson").join("meson.build"),
        Some(&fixture("meson").join("src/main.cpp")),
    )
    .expect("meson project parses");
    assert_eq!(
        command(&project, "build"),
        "meson compile -C build --target demo-app"
    );
    assert_eq!(
        command(&project, "run"),
        "meson compile -C build --target demo-app && ./build/demo-app"
    );
}

#[test]
fn parses_bazel_nested_build_targets_without_comment_injection() {
    let source = fixture("bazel").join("app/main.cc");
    let project =
        parse_project(ProjectKind::Bazel, &source, Some(&source)).expect("bazel project parses");
    assert_eq!(command(&project, "build-main"), "bazel build //app:main");
    assert_eq!(
        command(&project, "test-main_test"),
        "bazel test //app:main_test"
    );
}

#[test]
fn parses_maven_and_gradle_project_commands() {
    let maven = parse_project(ProjectKind::Maven, &fixture("maven").join("pom.xml"), None)
        .expect("maven project parses");
    assert_eq!(command(&maven, "build"), "mvn compile");
    assert_eq!(command(&maven, "run"), "mvn spring-boot:run");

    let gradle = parse_project(
        ProjectKind::Gradle,
        &fixture("gradle").join("build.gradle.kts"),
        None,
    )
    .expect("gradle project parses");
    assert_eq!(command(&gradle, "build"), "./gradlew build");
    assert_eq!(command(&gradle, "bootRun"), "./gradlew bootRun");
}

#[test]
fn parses_zig_steps_without_making_zig_a_backend_dependency() {
    let steps =
        parse_zig_steps("install (default) Copy artifacts\nrun Run app\nbench-fast Fast bench\n");
    assert_eq!(steps, vec!["install", "run", "bench-fast"]);
}

#[test]
fn malformed_complex_project_files_return_structured_errors() {
    let root = std::env::temp_dir().join(format!("zignite-invalid-complex-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project");
    fs::write(root.join("pom.xml"), "<project>").expect("write malformed pom");

    assert!(matches!(
        parse_project(ProjectKind::Maven, &root, None),
        Err(ProjectError::InvalidFile { .. })
    ));
    let _ = fs::remove_dir_all(root);
}
