use std::path::Path;

use crate::config::ConfigState;
use crate::paths::{dirname, quote_shell_arg};
use crate::runtime::materialize::{substitute_variables_shell, tokenize_command};

use super::resolve::resolve_build;
use super::types::{ActionKind, ActionPlan, BuildState};

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
            cwd: resolved
                .root
                .clone()
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
    let cwd = resolved
        .root
        .clone()
        .unwrap_or_else(|| dirname(&path.to_string_lossy()).to_owned());
    let tool = exec_argv.first().cloned();
    if let Some(tool) = tool.as_deref().filter(|tool| !is_shell_builtin(tool)) {
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
    let system_argv = system_argv(&exec_command, &exec_argv, config);
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
    if tokens.iter().any(|token| {
        token
            .bytes()
            .any(|byte| matches!(byte, b';' | b'|' | b'&' | b'<' | b'>' | b'`'))
    }) {
        return Err(super::BuildError::InvalidCommand(
            "unsafe command arguments".to_owned(),
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
    let has_shell_syntax = command
        .bytes()
        .any(|byte| matches!(byte, b'&' | b'|' | b';' | b'<' | b'>' | b'`'));
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

fn is_shell_builtin(tool: &str) -> bool {
    matches!(tool, "cd" | "export" | "set" | "env")
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
