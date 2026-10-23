use std::path::Path;

use super::common::{
    call_bodies, discovered_build_dir, push_command, shell_token, shell_word, strip_hash_comments,
    tokenize,
};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(
    root: ProjectRoot,
    kind: ProjectKind,
    match_path: Option<&Path>,
) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    let source = strip_hash_comments(&contents);
    let build_dir = shell_word(&discovered_build_dir(&root.root, "build.ninja").0);
    let mut project = Project::new(root, kind);
    let relative_match = match_path.and_then(|path| relative_path(&project.root, path));
    let basename = match_path
        .and_then(|path| path.file_name())
        .and_then(|name| name.to_str());
    let executables = call_bodies(&source, "executable")
        .into_iter()
        .map(|body| (body, true));
    let libraries = call_bodies(&source, "library")
        .into_iter()
        .map(|body| (body, false));
    let mut first_target = None;
    let mut matched_target = None;
    for (body, is_executable) in executables.chain(libraries) {
        let tokens = tokenize(&body);
        let Some(name) = tokens.first() else { continue };
        if !super::common::valid_name(name) {
            continue;
        }
        let matched = relative_match.as_deref().is_some_and(|candidate| {
            tokens.iter().skip(1).any(|token| token == candidate)
                || basename.is_some_and(|base| tokens.iter().skip(1).any(|token| token == base))
        });
        let target = (name.clone(), is_executable);
        first_target.get_or_insert_with(|| target.clone());
        if matched && matched_target.is_none() {
            matched_target = Some(target);
        }
        add_target(&mut project, name, &build_dir, is_executable);
    }
    if let Some((name, is_executable)) = matched_target.or(first_target) {
        add_default_target(&mut project, &name, &build_dir, is_executable);
    }
    Ok(project)
}

fn add_target(project: &mut Project, name: &str, build_dir: &str, is_executable: bool) {
    let quoted = shell_token(name);
    let build = format!("meson compile -C {build_dir} --target {quoted}");
    push_command(&mut project.commands, &format!("build-{name}"), &build);
    if is_executable {
        let run = format!("{build} && ./{build_dir}/{quoted}");
        push_command(&mut project.commands, &format!("run-{name}"), &run);
    }
}

fn add_default_target(project: &mut Project, name: &str, build_dir: &str, is_executable: bool) {
    let quoted = shell_token(name);
    let build = format!("meson compile -C {build_dir} --target {quoted}");
    push_command(&mut project.commands, "build", &build);
    if is_executable {
        let run = format!("{build} && ./{build_dir}/{quoted}");
        push_command(&mut project.commands, "run", &run);
    }
}

fn relative_path(root: &Path, path: &Path) -> Option<String> {
    let canonical = std::fs::canonicalize(path).ok()?;
    let relative = canonical.strip_prefix(root).ok()?;
    Some(relative.to_string_lossy().replace('\\', "/"))
}
