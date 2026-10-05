use std::fs;

use super::common::{invalid_payload, push_command, shell_token};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(root: ProjectRoot, kind: ProjectKind) -> Result<Project, ProjectError> {
    let _marker_contents = read_marker(&root)?;
    let pyproject = root.root.join("pyproject.toml");
    let pyproject_contents = if pyproject.is_file() {
        let contents = fs::read_to_string(&pyproject).map_err(|source| ProjectError::Io {
            path: pyproject.clone(),
            source,
        })?;
        contents
            .parse::<toml::Value>()
            .map_err(|error| super::common::invalid_file(&pyproject, error.to_string()))?;
        Some(contents)
    } else {
        None
    };
    let mut project = Project::new(root.clone(), kind);
    let profile = if root.root.join("uv.lock").is_file()
        || pyproject_contents
            .as_deref()
            .is_some_and(|contents| contents.lines().any(|line| line.trim() == "[tool.uv]"))
    {
        "uv"
    } else if root.root.join("environment.yml").is_file()
        || root.root.join("environment.yaml").is_file()
    {
        "conda"
    } else {
        "requirements"
    };

    match profile {
        "uv" => {
            push_command(&mut project.commands, "run", "uv run -m main");
            push_command(&mut project.commands, "test", "uv run pytest");
            push_command(&mut project.commands, "install", "uv sync");
        }
        "conda" => {
            let environment = root
                .root
                .join("environment.yml")
                .is_file()
                .then(|| root.root.join("environment.yml"))
                .or_else(|| {
                    root.root
                        .join("environment.yaml")
                        .is_file()
                        .then(|| root.root.join("environment.yaml"))
                });
            let environment_name = environment
                .and_then(|path| fs::read_to_string(path).ok())
                .and_then(|contents| parse_environment_name(&contents));
            let prefix = environment_name
                .as_deref()
                .filter(|name| !invalid_payload(name))
                .map(shell_token)
                .map(|name| format!("conda run -n {name}"))
                .unwrap_or_else(|| "conda run".to_owned());
            push_command(
                &mut project.commands,
                "run",
                &format!("{prefix} python -m main"),
            );
            push_command(&mut project.commands, "test", &format!("{prefix} pytest"));
            push_command(&mut project.commands, "install", "conda env update --prune");
        }
        _ => {
            push_command(&mut project.commands, "run", "python -m main");
            push_command(&mut project.commands, "test", "pytest");
            push_command(
                &mut project.commands,
                "install",
                "pip install -r requirements.txt",
            );
        }
    }
    Ok(project)
}

fn parse_environment_name(contents: &str) -> Option<String> {
    contents.lines().find_map(|line| {
        let value = line.split('#').next()?.trim().strip_prefix("name:")?.trim();
        let value = value.trim_matches(['"', '\'']);
        (!value.is_empty()).then(|| value.to_owned())
    })
}
