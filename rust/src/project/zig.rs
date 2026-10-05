use std::ffi::OsString;
use std::time::Duration;

use super::common::push_command;
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};
use crate::process::{run_argv, CommandSpec, ProcessError, TimeoutPolicy};

pub(super) fn parse(root: ProjectRoot, kind: ProjectKind) -> Result<Project, ProjectError> {
    let _ = read_marker(&root)?;
    let result = run_argv(
        &CommandSpec {
            argv: [
                "zig",
                "build",
                "--cache-dir",
                ".zig-cache",
                "--global-cache-dir",
                ".zig-global-cache",
                "-l",
            ]
            .into_iter()
            .map(OsString::from)
            .collect(),
            cwd: Some(root.root.clone()),
            env: Vec::new(),
        },
        TimeoutPolicy {
            timeout: Some(Duration::from_secs(30)),
            grace: Duration::from_millis(100),
        },
        None,
    )
    .map_err(|error| match error {
        ProcessError::MissingExecutable { program } => ProjectError::MissingTool { tool: program },
        _ => ProjectError::CommandFailed {
            tool: "zig build -l".to_owned(),
        },
    })?;
    if !result.status.success() {
        return Err(ProjectError::CommandFailed {
            tool: "zig build -l".to_owned(),
        });
    }

    let mut project = Project::new(root, kind);
    for step in parse_steps(&String::from_utf8_lossy(&result.stdout)) {
        push_command(
            &mut project.commands,
            &step,
            &format!("zig build {}", super::common::shell_token(&step)),
        );
    }
    Ok(project)
}

pub fn parse_steps(output: &str) -> Vec<String> {
    let mut steps = Vec::new();
    for line in output.lines().map(str::trim) {
        let Some(name) = line.split_whitespace().next() else {
            continue;
        };
        if name == "Usage:" || name.starts_with('-') || !super::common::valid_name(name) {
            continue;
        }
        if !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
        {
            continue;
        }
        if !steps.iter().any(|step| step == name) {
            steps.push(name.to_owned());
        }
    }
    steps
}
