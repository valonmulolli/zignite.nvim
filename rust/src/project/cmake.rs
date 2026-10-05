use std::path::Path;

use super::common::{call_bodies, push_command, shell_token, strip_hash_comments, tokenize};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(
    root: ProjectRoot,
    kind: ProjectKind,
    match_path: Option<&Path>,
) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    let source = strip_hash_comments(&contents);
    let mut project = Project::new(root.clone(), kind);
    let relative_match = match_path.and_then(|path| relative_path(&root.root, path));
    let basename = match_path
        .and_then(|path| path.file_name())
        .and_then(|name| name.to_str());

    for body in call_bodies(&source, "add_executable")
        .into_iter()
        .chain(call_bodies(&source, "add_library"))
    {
        let tokens = tokenize(&body);
        let Some(name) = tokens.first() else { continue };
        if name.starts_with("${") || !super::common::valid_name(name) {
            continue;
        }
        let matched = relative_match.as_deref().is_some_and(|candidate| {
            tokens.iter().skip(1).any(|token| token == candidate)
                || basename.is_some_and(|base| tokens.iter().skip(1).any(|token| token == base))
        });
        add_target(&mut project, name, matched);
    }
    Ok(project)
}

fn add_target(project: &mut Project, name: &str, matched: bool) {
    let quoted = shell_token(name);
    let build = format!("cmake --build build --target {quoted}");
    let run = format!("cmake --build build --target {quoted} && ./build/{quoted}");
    let _ = matched;
    push_command(&mut project.commands, "build", &build);
    push_command(&mut project.commands, "run", &run);
    push_command(&mut project.commands, &format!("build-{name}"), &build);
    push_command(&mut project.commands, &format!("run-{name}"), &run);
}

fn relative_path(root: &Path, path: &Path) -> Option<String> {
    let canonical = std::fs::canonicalize(path).ok()?;
    let relative = canonical.strip_prefix(root).ok()?;
    Some(relative.to_string_lossy().replace('\\', "/"))
}
