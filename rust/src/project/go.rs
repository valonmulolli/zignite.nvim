use std::fs;
use std::path::{Path, PathBuf};

use super::common::{invalid_payload, push_command, shell_token};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(
    root: ProjectRoot,
    kind: ProjectKind,
    match_path: Option<&Path>,
) -> Result<Project, ProjectError> {
    let marker_contents = read_marker(&root)?;
    let mut project = Project::new(root.clone(), kind);
    let module_path = if root.marker.file_name().and_then(|name| name.to_str()) == Some("go.work") {
        workspace_module_path(&root, &marker_contents, match_path)
    } else {
        Some(root.marker.clone())
    };

    if let Some(module_path) = module_path {
        let contents = fs::read_to_string(&module_path).map_err(|source| ProjectError::Io {
            path: module_path.clone(),
            source,
        })?;
        if let Some(module) = parse_module_name(&contents) {
            if !invalid_payload(module) {
                project.module = Some(module.to_owned());
            }
        }
    }

    let selector = package_selector(&root.root, match_path);
    project.primary_selector = Some(selector.clone());
    let quoted = shell_token(&selector);
    push_command(
        &mut project.commands,
        "build",
        &format!("go build {quoted}"),
    );
    push_command(&mut project.commands, "run", &format!("go run {quoted}"));
    push_command(&mut project.commands, "test", &format!("go test {quoted}"));
    Ok(project)
}

fn parse_module_name(contents: &str) -> Option<&str> {
    contents.lines().find_map(|line| {
        let line = line.split("//").next()?.trim();
        let value = line.strip_prefix("module")?;
        if value.is_empty() || !value.chars().next().is_some_and(char::is_whitespace) {
            return None;
        }
        let value = value.trim();
        if value.is_empty() {
            return None;
        }
        Some(value.trim_matches(['"', '\'', '`']))
    })
}

fn package_selector(root: &Path, match_path: Option<&Path>) -> String {
    let Some(path) = match_path else {
        return ".".to_owned();
    };
    let Ok(canonical) = fs::canonicalize(path) else {
        return ".".to_owned();
    };
    let directory = if canonical.is_file() {
        canonical.parent().unwrap_or(&canonical)
    } else {
        &canonical
    };
    let Ok(relative) = directory.strip_prefix(root) else {
        return ".".to_owned();
    };
    if relative.as_os_str().is_empty() {
        ".".to_owned()
    } else {
        format!("./{}", relative.to_string_lossy().replace('\\', "/"))
    }
}

fn workspace_module_path(
    root: &ProjectRoot,
    contents: &str,
    match_path: Option<&Path>,
) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    let mut in_use = false;
    for raw_line in contents.lines() {
        let line = raw_line.split("//").next()?.trim();
        if line == "use(" || line == "use (" {
            in_use = true;
            continue;
        }
        if in_use && line == ")" {
            in_use = false;
            continue;
        }
        let value = if in_use {
            line
        } else if let Some(value) = line.strip_prefix("use ") {
            value.trim()
        } else {
            continue;
        };
        let value = value.trim_matches(['"', '\'', '`']);
        if value.is_empty() || invalid_payload(value) {
            continue;
        }
        let path = if Path::new(value).is_absolute() {
            PathBuf::from(value)
        } else {
            root.root.join(value)
        };
        if path.join("go.mod").is_file() {
            candidates.push(path);
        }
    }
    let matched = match_path.and_then(|path| {
        let canonical = fs::canonicalize(path).ok()?;
        candidates
            .iter()
            .find(|candidate| canonical.starts_with(candidate))
            .cloned()
    });
    matched
        .or_else(|| candidates.into_iter().next())
        .map(|path| path.join("go.mod"))
}
