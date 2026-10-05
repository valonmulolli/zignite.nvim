mod common;

use common::TempProject;
use std::fs;

use zignite::project::{parse_project, ProjectCommand, ProjectError, ProjectKind};

fn command<'a>(project: &'a zignite::project::Project, name: &str) -> &'a ProjectCommand {
    project
        .commands
        .iter()
        .find(|command| command.name == name)
        .unwrap_or_else(|| panic!("missing command {name}"))
}

#[test]
fn parses_make_targets_without_recipe_or_variable_false_positives() {
    let root = TempProject::new("make");
    let makefile = root.write(
        "Makefile",
        "CC=gcc\n.PHONY: build test\nbuild test: all\n\t@true\nunsafe;touch:\n\t@true\n",
    );

    let project = parse_project(ProjectKind::Make, &makefile, None).expect("make parse succeeds");
    assert_eq!(command(&project, "build").command, "make build");
    assert_eq!(command(&project, "test").command, "make test");
    assert!(project.commands.iter().all(|item| item.name != "CC"));
    assert!(project.commands.iter().all(|item| !item.name.contains(";")));
}

#[test]
fn parses_package_scripts_and_lockfile_package_manager() {
    let root = TempProject::new("node");
    let package_json = root.write(
        "package.json",
        r#"{"name":"demo-node-app","scripts":{"dev":"vite","build":"vite build","test":"vitest"}}"#,
    );
    root.write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n");

    let project = parse_project(ProjectKind::PackageJson, &package_json, None)
        .expect("package project parses");

    assert_eq!(
        project.root,
        fs::canonicalize(root.path()).expect("canonical temporary project")
    );
    assert_eq!(command(&project, "dev").command, "pnpm run dev");
    assert_eq!(command(&project, "test").command, "pnpm test");
}

#[test]
fn parses_cargo_bins_and_matches_the_source_bin() {
    let root = TempProject::new("cargo");
    root.write(
        "Cargo.toml",
        "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
    );
    root.write("src/main.rs", "fn main() {}\n");
    let source = root.write("src/bin/api.rs", "fn main() {}\n");
    let project =
        parse_project(ProjectKind::Cargo, &source, Some(&source)).expect("cargo project parses");

    assert_eq!(command(&project, "api").command, "cargo run --bin api");
    assert!(project.commands.iter().any(|item| item.name == "run-api"));
}

#[test]
fn parses_go_module_package_commands() {
    let root = TempProject::new("go");
    root.write("go.mod", "module github.com/example/demo\n\ngo 1.24.0\n");
    let source = root.write("cmd/api/main.go", "package main\n\nfunc main() {}\n");
    let project =
        parse_project(ProjectKind::Go, &source, Some(&source)).expect("go project parses");

    assert_eq!(project.module.as_deref(), Some("github.com/example/demo"));
    assert_eq!(project.primary_selector.as_deref(), Some("./cmd/api"));
    assert_eq!(command(&project, "run").command, "go run ./cmd/api");
    assert_eq!(command(&project, "test").command, "go test ./cmd/api");
}

#[test]
fn parses_go_workspace_and_selects_the_matching_module() {
    let root = TempProject::new("go-work");
    root.write("go.work", "go 1.24.0\n\nuse ./service\n");
    root.write(
        "service/go.mod",
        "module github.com/example/workspace-service\n\ngo 1.24.0\n",
    );
    let source = root.write(
        "service/cmd/api/main.go",
        "package main\n\nfunc main() {}\n",
    );
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
fn parses_python_uv_project() {
    let root = TempProject::new("python");
    root.write(
        "pyproject.toml",
        "[project]\nname = \"demo-python-app\"\nversion = \"0.1.0\"\n\n[tool.uv]\nversion = 1\n",
    );
    root.write("uv.lock", "version = 1\n");
    let source = root.write("app/main.py", "print('hello')\n");
    let project = parse_project(ProjectKind::Python, &source, None).expect("python project parses");

    assert_eq!(command(&project, "run").command, "uv run -m main");
    assert_eq!(command(&project, "test").command, "uv run pytest");
    assert_eq!(command(&project, "install").command, "uv sync");
}

#[test]
fn malformed_project_files_return_structured_errors() {
    let root = TempProject::new("invalid-project");
    root.write("package.json", "{not json");

    assert!(matches!(
        parse_project(ProjectKind::PackageJson, root.path(), None),
        Err(ProjectError::InvalidFile { .. })
    ));
}
