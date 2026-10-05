use std::path::Path;

use toml::Value;

use super::common::{push_command, shell_token};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(
    root: ProjectRoot,
    kind: ProjectKind,
    match_path: Option<&Path>,
) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    let value: Value = contents.parse().map_err(|error: toml::de::Error| {
        super::common::invalid_file(&root.marker, error.to_string())
    })?;
    let package_name = value
        .get("package")
        .and_then(Value::as_table)
        .and_then(|package| package.get("name"))
        .and_then(Value::as_str);
    let relative_match = relative_match_path(&root.root, match_path);
    let mut project = Project::new(root, kind);

    if let Some(bins) = value.get("bin").and_then(Value::as_array) {
        for bin in bins {
            let Some(table) = bin.as_table() else {
                continue;
            };
            let Some(name) = table.get("name").and_then(Value::as_str) else {
                continue;
            };
            let path = table.get("path").and_then(Value::as_str);
            let matched = relative_match.as_deref().is_some_and(|candidate| {
                path.map_or(candidate == format!("src/bin/{name}.rs"), |path| {
                    candidate == path
                })
            });
            add_bin_commands(&mut project, name, matched);
        }
    }

    if let Some(name) = package_name {
        if relative_match.as_deref() == Some("src/main.rs") {
            add_bin_commands(&mut project, name, true);
        }
    }
    if let Some(candidate) = relative_match.as_deref().and_then(bin_name_from_path) {
        add_bin_commands(&mut project, candidate, true);
    }
    if project.commands.is_empty() {
        push_command(&mut project.commands, "build", "cargo build");
        push_command(&mut project.commands, "run", "cargo run");
        push_command(&mut project.commands, "test", "cargo test");
    }
    Ok(project)
}

fn add_bin_commands(project: &mut Project, name: &str, matched: bool) {
    let quoted = shell_token(name);
    push_command(
        &mut project.commands,
        name,
        &format!("cargo run --bin {quoted}"),
    );
    push_command(
        &mut project.commands,
        &format!("run-{name}"),
        &format!("cargo run --bin {quoted}"),
    );
    push_command(
        &mut project.commands,
        &format!("build-{name}"),
        &format!("cargo build --bin {quoted}"),
    );
    push_command(
        &mut project.commands,
        &format!("test-{name}"),
        &format!("cargo test --bin {quoted}"),
    );
    if matched {
        project.primary_selector = Some(name.to_owned());
    }
}

fn relative_match_path(root: &Path, match_path: Option<&Path>) -> Option<String> {
    let path = match_path?;
    let canonical = std::fs::canonicalize(path).ok()?;
    let relative = canonical.strip_prefix(root).ok()?;
    Some(relative.to_string_lossy().replace('\\', "/"))
}

fn bin_name_from_path(path: &str) -> Option<&str> {
    let name = path.strip_prefix("src/bin/")?.strip_suffix(".rs")?;
    (!name.is_empty() && !name.contains('/')).then_some(name)
}
