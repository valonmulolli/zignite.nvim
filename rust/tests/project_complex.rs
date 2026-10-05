mod common;

use common::TempProject;
use zignite::project::{parse_project, parse_zig_steps, ProjectError, ProjectKind};

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
    let root = TempProject::new("cmake");
    root.write(
        "CMakeLists.txt",
        "set(note \"# add_executable(fake src/fake.cpp)\")\n# add_executable(comment src/comment.cpp)\nadd_executable(real src/main.cpp)\n",
    );
    let source = root.write("src/main.cpp", "int main() { return 0; }\n");

    let project = parse_project(ProjectKind::CMake, root.path(), Some(&source))
        .expect("cmake project parses");
    assert_eq!(
        command(&project, "build"),
        "cmake --build build --target real"
    );
    assert!(project.commands.iter().all(|item| item.name != "fake"));
    assert!(project.commands.iter().all(|item| item.name != "comment"));
}

#[test]
fn parses_meson_target() {
    let root = TempProject::new("meson");
    let build = root.write(
        "meson.build",
        "project('demo', 'cpp')\nexecutable('demo-app', 'src/main.cpp')\n",
    );
    let source = root.write("src/main.cpp", "int main() { return 0; }\n");
    let project =
        parse_project(ProjectKind::Meson, &build, Some(&source)).expect("meson project parses");
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
    let root = TempProject::new("bazel");
    root.write(
        "MODULE.bazel",
        "bazel_dep(name = \"rules_cc\", version = \"0.0.9\")\n",
    );
    root.write(
        "app/BUILD.bazel",
        "cc_binary(name = \"main\", srcs = [\"main.cc\"])\n\ncc_test(name = \"main_test\", srcs = [\"main_test.cc\"])\n",
    );
    let source = root.write("app/main.cc", "int main() { return 0; }\n");
    root.write("app/main_test.cc", "int main() { return 0; }\n");
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
    let maven_root = TempProject::new("maven");
    let pom = maven_root.write(
        "pom.xml",
        "<project><modelVersion>4.0.0</modelVersion><groupId>com.example</groupId><artifactId>demo</artifactId><version>1.0.0</version><build><plugins><plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>",
    );
    let maven = parse_project(ProjectKind::Maven, &pom, None).expect("maven project parses");
    assert_eq!(command(&maven, "build"), "mvn compile");
    assert_eq!(command(&maven, "run"), "mvn spring-boot:run");

    let gradle_root = TempProject::new("gradle");
    let build = gradle_root.write(
        "build.gradle.kts",
        "plugins { id(\"application\"); id(\"org.springframework.boot\") version \"3.5.0\" }\n",
    );
    gradle_root.write("gradlew", "#!/bin/sh\n");
    let gradle = parse_project(ProjectKind::Gradle, &build, None).expect("gradle project parses");
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
    let root = TempProject::new("invalid-complex");
    root.write("pom.xml", "<project>");

    assert!(matches!(
        parse_project(ProjectKind::Maven, root.path(), None),
        Err(ProjectError::InvalidFile { .. })
    ));
}
