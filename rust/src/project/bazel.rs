use std::path::{Path, PathBuf};

use super::common::{call_bodies, push_command, shell_token, strip_hash_comments, tokenize};
use super::core::{Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(
    root: ProjectRoot,
    kind: ProjectKind,
    match_path: Option<&Path>,
) -> Result<Project, ProjectError> {
    let build_file = find_build_file(&root, match_path).ok_or_else(|| {
        super::common::invalid_file(&root.marker, "no BUILD file found for the project")
    })?;
    let contents = std::fs::read_to_string(&build_file).map_err(|source| ProjectError::Io {
        path: build_file.clone(),
        source,
    })?;
    let source = strip_hash_comments(&contents);
    let package = build_file
        .parent()
        .and_then(|path| path.strip_prefix(&root.root).ok())
        .map(|path| path.to_string_lossy().replace('\\', "/"))
        .filter(|path| !path.is_empty());
    let mut project = Project::new(root, kind);
    for rule in [
        "cc_binary",
        "cc_test",
        "cc_library",
        "go_binary",
        "go_test",
        "java_binary",
        "java_test",
        "py_binary",
        "py_test",
    ] {
        for body in call_bodies(&source, rule) {
            let name = named_attribute(&body, "name").or_else(|| tokenize(&body).first().cloned());
            let Some(name) = name else { continue };
            if !super::common::valid_name(&name) {
                continue;
            }
            let label = match &package {
                Some(package) => format!("//{package}:{name}"),
                None => format!("//:{name}"),
            };
            let command = if rule.ends_with("_test") {
                "test"
            } else {
                "build"
            };
            let quoted = shell_token(&label);
            push_command(
                &mut project.commands,
                &format!("{command}-{name}"),
                &format!("bazel {command} {quoted}"),
            );
        }
    }
    Ok(project)
}

fn find_build_file(root: &ProjectRoot, match_path: Option<&Path>) -> Option<PathBuf> {
    let mut current = match_path
        .and_then(|path| std::fs::canonicalize(path).ok())
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| root.root.clone());
    loop {
        for name in ["BUILD.bazel", "BUILD"] {
            let candidate = current.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        if current == root.root {
            break;
        }
        let Some(parent) = current.parent() else {
            break;
        };
        current = parent.to_path_buf();
    }
    None
}

fn named_attribute(body: &str, name: &str) -> Option<String> {
    let tokens = tokenize(body);
    tokens
        .windows(3)
        .find(|window| window[0] == name && window[1] == "=")
        .map(|window| window[2].to_owned())
}
