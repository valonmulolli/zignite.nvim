use super::core::{ProjectCommand, ProjectError};
use crate::paths::quote_shell_arg;

const PROTOCOL_MARKERS: [&str; 8] = [
    "@@ZQF_", "@@ZBR_", "@@ZDET_", "@@ZPRJ_", "@@ZCFG_", "@@ZBA_", "@@ZRUN_", "@@ZHLT_",
];

pub fn invalid_payload(value: &str) -> bool {
    value.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
        || PROTOCOL_MARKERS.iter().any(|marker| value.contains(marker))
}

pub fn valid_name(value: &str) -> bool {
    !value.is_empty() && !invalid_payload(value) && !value.chars().any(char::is_whitespace)
}

pub fn shell_token(value: &str) -> String {
    if value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_./:@%+-".contains(&byte))
    {
        value.to_owned()
    } else {
        quote_shell_arg(value)
    }
}

pub fn push_command(commands: &mut Vec<ProjectCommand>, name: &str, command: &str) {
    if !valid_name(name) || invalid_payload(command) {
        return;
    }
    if commands
        .iter()
        .any(|item| item.name == name && item.command == command)
    {
        return;
    }
    commands.push(ProjectCommand {
        name: name.to_owned(),
        command: command.to_owned(),
    });
}

pub fn invalid_file(path: &std::path::Path, message: impl Into<String>) -> ProjectError {
    ProjectError::InvalidFile {
        path: path.to_path_buf(),
        message: message.into(),
    }
}
