use serde_json::Value;

use super::common::{push_command, shell_token};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(root: ProjectRoot, kind: ProjectKind) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    let value: Value = serde_json::from_str(&contents)
        .map_err(|error| super::common::invalid_file(&root.marker, error.to_string()))?;
    let object = value
        .as_object()
        .ok_or_else(|| super::common::invalid_file(&root.marker, "root must be a JSON object"))?;

    let manager = object
        .get("packageManager")
        .and_then(Value::as_str)
        .and_then(|value| value.split('@').next())
        .filter(|value| matches!(*value, "npm" | "pnpm" | "yarn" | "bun"))
        .map(str::to_owned)
        .unwrap_or_else(|| detect_lockfile_manager(&root.root));

    let mut project = Project::new(root, kind);
    let Some(scripts) = object.get("scripts").and_then(Value::as_object) else {
        return Ok(project);
    };
    for (name, value) in scripts {
        if !value.is_string() {
            continue;
        }
        push_command(&mut project.commands, name, &script_command(&manager, name));
    }
    Ok(project)
}

fn detect_lockfile_manager(root: &std::path::Path) -> String {
    if root.join("bun.lockb").is_file() || root.join("bun.lock").is_file() {
        "bun".to_owned()
    } else if root.join("pnpm-lock.yaml").is_file() {
        "pnpm".to_owned()
    } else if root.join("yarn.lock").is_file() {
        "yarn".to_owned()
    } else {
        "npm".to_owned()
    }
}

fn script_command(manager: &str, name: &str) -> String {
    let quoted = shell_token(name);
    match manager {
        "bun" => format!("bun run {quoted}"),
        "yarn" => format!("yarn {quoted}"),
        "pnpm" if matches!(name, "start" | "test") => format!("pnpm {quoted}"),
        "pnpm" => format!("pnpm run {quoted}"),
        _ if matches!(name, "start" | "test") => format!("npm {quoted}"),
        _ => format!("npm run {quoted}"),
    }
}
