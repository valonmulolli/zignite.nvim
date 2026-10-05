use std::fs;
use std::path::{Path, PathBuf};

use zignite::project::{parse_project, ProjectCommand, ProjectError, ProjectKind};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("test_fixtures")
        .join(name)
}

fn command<'a>(project: &'a zignite::project::Project, name: &str) -> &'a ProjectCommand {
    project
        .commands
        .iter()
        .find(|command| command.name == name)
        .unwrap_or_else(|| panic!("missing command {name}"))
}

#[test]
fn parses_make_targets_without_recipe_or_variable_false_positives() {
    let root = std::env::temp_dir().join(format!("zignite-make-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create make project");
    fs::write(
        root.join("Makefile"),
        "CC=gcc\n.PHONY: build test\nbuild test: all\n\t@true\nunsafe;touch:\n\t@true\n",
    )
    .expect("write Makefile");

    let project = parse_project(ProjectKind::Make, &root.join("Makefile"), None)
        .expect("make parse succeeds");
    assert_eq!(command(&project, "build").command, "make build");
    assert_eq!(command(&project, "test").command, "make test");
    assert!(project.commands.iter().all(|item| item.name != "CC"));
    assert!(project.commands.iter().all(|item| !item.name.contains(";")));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn parses_package_scripts_and_lockfile_package_manager() {
    let project = parse_project(
        ProjectKind::PackageJson,
        &fixture("node").join("package.json"),
        None,
    )
    .expect("package project parses");

    assert_eq!(
        project.root,
        fs::canonicalize(fixture("node")).expect("canonical fixture")
    );
    assert_eq!(command(&project, "dev").command, "pnpm run dev");
    assert_eq!(command(&project, "test").command, "pnpm test");
}

#[test]
fn parses_cargo_bins_and_matches_the_source_bin() {
    let source = fixture("cargo").join("src/bin/api.rs");
    let project =
        parse_project(ProjectKind::Cargo, &source, Some(&source)).expect("cargo project parses");

    assert_eq!(command(&project, "api").command, "cargo run --bin api");
    assert!(project.commands.iter().any(|item| item.name == "run-api"));
}

#[test]
fn parses_go_module_package_commands() {
    let source = fixture("go").join("cmd/api/main.go");
    let project =
        parse_project(ProjectKind::Go, &source, Some(&source)).expect("go project parses");

    assert_eq!(project.module.as_deref(), Some("github.com/example/demo"));
    assert_eq!(project.primary_selector.as_deref(), Some("./cmd/api"));
    assert_eq!(command(&project, "run").command, "go run ./cmd/api");
    assert_eq!(command(&project, "test").command, "go test ./cmd/api");
}

#[test]
fn parses_go_workspace_and_selects_the_matching_module() {
    let source = fixture("go_work").join("service/cmd/api/main.go");
    let project =
        parse_project(ProjectKind::Go, &source, Some(&source)).expect("go workspace parses");

    assert_eq!(
        project.marker.file_name().and_then(|name| name.to_str()),
        Some("go.work")
    );
    assert_eq!(
        project.module.as_deref(),
        Some("github.com/example/workspace-service")
    );
    assert_eq!(
        project.primary_selector.as_deref(),
        Some("./service/cmd/api")
    );
    assert_eq!(command(&project, "run").command, "go run ./service/cmd/api");
}

#[test]
fn parses_python_uv_fixture() {
    let project = parse_project(
        ProjectKind::Python,
        &fixture("python").join("app/main.py"),
        None,
    )
    .expect("python project parses");

    assert_eq!(command(&project, "run").command, "uv run -m main");
    assert_eq!(command(&project, "test").command, "uv run pytest");
    assert_eq!(command(&project, "install").command, "uv sync");
}

#[test]
fn malformed_project_files_return_structured_errors() {
    let root = std::env::temp_dir().join(format!("zignite-invalid-project-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).expect("create project");
    fs::write(root.join("package.json"), "{not json").expect("write malformed json");

    assert!(matches!(
        parse_project(ProjectKind::PackageJson, &root, None),
        Err(ProjectError::InvalidFile { .. })
    ));
    let _ = fs::remove_dir_all(root);
}
