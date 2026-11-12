use std::path::Path;

use crate::config::ConfigState;
use crate::paths::{dirname, quote_shell_arg};
use crate::runtime::materialize::{
    first_external_program, requires_shell, substitute_variables_shell, tokenize_command,
};

use super::resolve::resolve_build;
use super::types::{ActionKind, ActionPlan, BuildSource, BuildState};

pub fn resolve_action(
    config: &ConfigState,
    state: &mut BuildState,
    path: &Path,
    requested_filetype: &str,
    action: ActionKind,
    command_name: Option<&str>,
    command_args: Option<&str>,
) -> Result<ActionPlan, super::BuildError> {
    let resolved = resolve_build(config, path, requested_filetype, None)?;
    let filetype = resolved.filetype.clone();
    let selected_name = match action {
        ActionKind::Named => command_name.map(str::to_owned).ok_or_else(|| {
            super::BuildError::InvalidOptions("named action requires a command name".to_owned())
        })?,
        ActionKind::Live => "live".to_owned(),
        ActionKind::Last => match state.last(&filetype) {
            Some(name) => name.to_owned(),
            None => {
                return Ok(failure(
                    &filetype,
                    config.revision(),
                    "missing_last_command",
                    format!("No previous build command for filetype: {filetype}"),
                ))
            }
        },
    };
    let Some(entry) = resolved.command(&selected_name) else {
        if action == ActionKind::Last {
            state.clear(&filetype);
        }
        let reason = match action {
            ActionKind::Live => "missing_live_command",
            ActionKind::Last => "stale_last_command",
            ActionKind::Named => "missing_command",
        };
        return Ok(failure(
            &filetype,
            config.revision(),
            reason,
            format!("Command '{selected_name}' not found for {filetype}."),
        )
        .with_command_name(selected_name));
    };
    if entry.requires_arguments && command_args.map(str::trim).is_none_or(str::is_empty) {
        return Ok(ActionPlan {
            ok: false,
            reason: Some("missing_arguments".to_owned()),
            message: Some(format!(
                "Command '{}' for {} requires additional arguments.",
                entry.name, filetype
            )),
            resolved_command_name: Some(entry.name.clone()),
            requires_arguments: true,
            argument_prompt: entry.argument_prompt.clone(),
            argument_help: entry.argument_help.clone(),
            filetype: Some(filetype),
            cwd: entry
                .cwd
                .clone()
                .or_else(|| resolved.root.clone())
                .or_else(|| Some(dirname(&path.to_string_lossy()).to_owned())),
            name: Some(format!("{}: {}", requested_filetype, entry.name)),
            missing_tool: None,
            exec_command: None,
            exec_argv: Vec::new(),
            system_argv: Vec::new(),
            config_revision: config.revision(),
        });
    }
    let command = materialize_arguments(&entry.command, &filetype, &entry.name, command_args)?;
    let exec_command = substitute_variables_shell(&command, &path.to_string_lossy());
    let exec_argv = tokenize_command(&exec_command).map_err(super::BuildError::InvalidCommand)?;
    let cwd = entry
        .cwd
        .clone()
        .or_else(|| resolved.root.clone())
        .unwrap_or_else(|| dirname(&path.to_string_lossy()).to_owned());
    let tool = first_external_program(&exec_command);
    if let Some(tool) = tool.as_deref() {
        if !state.tool_available(tool, &cwd) {
            return Ok(ActionPlan {
                ok: false,
                reason: Some("missing_tool".to_owned()),
                message: Some(format!(
                    "Error: Required executable '{tool}' was not found in PATH."
                )),
                resolved_command_name: Some(entry.name.clone()),
                requires_arguments: false,
                argument_prompt: None,
                argument_help: None,
                filetype: Some(filetype),
                cwd: Some(cwd),
                name: Some(format!("{}: {}", requested_filetype, entry.name)),
                missing_tool: Some(tool.to_owned()),
                exec_command: Some(exec_command),
                exec_argv,
                system_argv: Vec::new(),
                config_revision: config.revision(),
            });
        }
    }
    state.remember(&filetype, &entry.name);
    let system_argv = if resolved.system.as_deref() == Some("cmake")
        && entry.source == BuildSource::Project
        && (selected_name == "run" || selected_name.starts_with("run-"))
    {
        let project_root = resolved.root.as_deref().ok_or_else(|| {
            super::BuildError::InvalidCommand("CMake project root is unavailable".to_owned())
        })?;
        cmake_run_target_argv(project_root, &entry.command, config.execution_timeout()).ok_or_else(
            || {
                super::BuildError::InvalidCommand(
                    "could not resolve the CMake executable target".to_owned(),
                )
            },
        )?
    } else {
        system_argv(&exec_command, &exec_argv, config)
    };
    Ok(ActionPlan {
        ok: true,
        reason: None,
        message: None,
        resolved_command_name: Some(entry.name.clone()),
        requires_arguments: false,
        argument_prompt: None,
        argument_help: None,
        filetype: Some(filetype),
        cwd: Some(cwd),
        name: Some(format!("{}: {}", requested_filetype, entry.name)),
        missing_tool: None,
        exec_command: Some(exec_command),
        exec_argv,
        system_argv,
        config_revision: config.revision(),
    })
}

fn cmake_run_target_argv(
    project_root: &str,
    command: &str,
    timeout: Option<std::time::Duration>,
) -> Option<Vec<String>> {
    let tokens = command
        .split("&&")
        .filter_map(|segment| tokenize_command(segment).ok())
        .find(|tokens| {
            tokens.first().map(String::as_str) == Some("cmake")
                && tokens.iter().any(|token| token == "--build")
        })?;
    let build_dir = option_argument(&tokens, "--build")?;
    let target = option_argument(&tokens, "--target")?;
    let project_root_path = Path::new(project_root);
    let build_dir = Path::new(build_dir);
    let build_dir = if build_dir.is_absolute() {
        build_dir.to_path_buf()
    } else {
        project_root_path.join(build_dir)
    };
    let executable = std::env::current_exe()
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| "zignite".to_owned());
    let mut argv = vec![
        executable,
        "--cmake-run-target".to_owned(),
        format!("--source-dir={project_root}"),
        format!("--build-dir={}", build_dir.to_string_lossy()),
        format!("--target={target}"),
    ];
    if let Some(timeout) = timeout {
        argv.push(format!(
            "--timeout-ms={}",
            timeout.as_millis().min(u64::MAX as u128)
        ));
    }
    Some(argv)
}

fn option_argument<'a>(tokens: &'a [String], option: &str) -> Option<&'a str> {
    let index = tokens.iter().position(|token| token == option)?;
    tokens.get(index + 1).map(String::as_str)
}

fn materialize_arguments(
    command: &str,
    filetype: &str,
    command_name: &str,
    arguments: Option<&str>,
) -> Result<String, super::BuildError> {
    let Some(arguments) = arguments else {
        return Ok(command.to_owned());
    };
    let arguments = arguments.trim();
    if arguments.is_empty() {
        return Ok(command.to_owned());
    }
    let tokens = tokenize_command(arguments).map_err(super::BuildError::InvalidCommand)?;
    if tokens.is_empty() {
        return Err(super::BuildError::InvalidCommand(
            "empty command arguments".to_owned(),
        ));
    }
    let replacement = if filetype == "zig" && command_name == "fetch" {
        let value = tokens.first().expect("checked non-empty");
        let value = if value.starts_with("git+") {
            value.clone()
        } else if value.starts_with("http://") || value.starts_with("https://") {
            format!("git+{value}")
        } else if value.matches('/').count() == 1 && !value.contains(char::is_whitespace) {
            format!("git+https://github.com/{value}")
        } else {
            value.clone()
        };
        format!("--save {}", quote_shell_arg(&value))
    } else {
        tokens
            .iter()
            .map(|token| quote_shell_arg(token))
            .collect::<Vec<_>>()
            .join(" ")
    };
    Ok(command.replace("$zignite_args", &replacement))
}

fn system_argv(command: &str, argv: &[String], config: &ConfigState) -> Vec<String> {
    let has_shell_syntax = requires_shell(command, argv);
    if cfg!(unix) && !has_shell_syntax && config.execution_timeout().is_none() {
        return argv.to_vec();
    }
    let executable = std::env::current_exe()
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| "zignite".to_owned());
    let mut wrapped = vec![executable];
    if let Some(timeout) = config.execution_timeout() {
        wrapped.push(format!("--timeout={}", timeout.as_millis()));
    }
    if cfg!(windows) || has_shell_syntax {
        wrapped.push(command.to_owned());
    } else {
        wrapped.push("--argv".to_owned());
        wrapped.extend(argv.iter().cloned());
    }
    wrapped
}

fn failure(filetype: &str, revision: u64, reason: &str, message: String) -> ActionPlan {
    ActionPlan {
        ok: false,
        reason: Some(reason.to_owned()),
        message: Some(message),
        resolved_command_name: None,
        requires_arguments: false,
        argument_prompt: None,
        argument_help: None,
        filetype: Some(filetype.to_owned()),
        cwd: None,
        name: None,
        missing_tool: None,
        exec_command: None,
        exec_argv: Vec::new(),
        system_argv: Vec::new(),
        config_revision: revision,
    }
}

impl ActionPlan {
    fn with_command_name(mut self, name: String) -> Self {
        self.resolved_command_name = Some(name);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::cmake_run_target_argv;
    use std::time::Duration;

    #[test]
    fn cmake_run_action_passes_target_paths_as_backend_arguments() {
        let argv = cmake_run_target_argv(
            "/tmp/project with spaces",
            "cmake --build build --target demo && ./build/demo",
            Some(Duration::from_secs(3)),
        )
        .expect("CMake run command parses");

        assert_eq!(argv[1], "--cmake-run-target");
        assert_eq!(argv[2], "--source-dir=/tmp/project with spaces");
        assert_eq!(argv[3], "--build-dir=/tmp/project with spaces/build");
        assert_eq!(argv[4], "--target=demo");
        assert_eq!(argv[5], "--timeout-ms=3000");
    }
}
