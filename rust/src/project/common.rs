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

pub fn strip_hash_comments(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut quote = None;
    let mut escaped = false;
    let mut comment = false;
    for byte in value.bytes() {
        if comment {
            if byte == b'\n' {
                comment = false;
                result.push('\n');
            } else {
                result.push(' ');
            }
            continue;
        }
        if let Some(active) = quote {
            result.push(byte as char);
            if active == b'"' && escaped {
                escaped = false;
            } else if active == b'"' && byte == b'\\' {
                escaped = true;
            } else if byte == active {
                quote = None;
            }
            continue;
        }
        if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
            result.push(byte as char);
        } else if byte == b'#' {
            comment = true;
            result.push(' ');
        } else {
            result.push(byte as char);
        }
    }
    result
}

pub fn call_bodies(source: &str, name: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut offset = 0usize;
    let mut quote = None;
    let mut escaped = false;
    while offset < source.len() {
        let byte = source.as_bytes()[offset];
        if let Some(active) = quote {
            if active == b'"' && escaped {
                escaped = false;
            } else if active == b'"' && byte == b'\\' {
                escaped = true;
            } else if byte == active {
                quote = None;
            }
            offset += 1;
            continue;
        }
        if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
            offset += 1;
            continue;
        }
        if source[offset..].starts_with(name)
            && (offset == 0
                || !(source.as_bytes()[offset - 1].is_ascii_alphanumeric()
                    || source.as_bytes()[offset - 1] == b'_'))
        {
            let after_name = offset + name.len();
            let Some(open_relative) = source[after_name..].find('(') else {
                break;
            };
            let open = after_name + open_relative;
            if source[after_name..open].trim().is_empty() {
                if let Some(close) = matching_paren(source, open) {
                    result.push(source[open + 1..close].to_owned());
                    offset = close + 1;
                    continue;
                }
                break;
            }
        }
        offset += 1;
    }
    result
}

pub fn tokenize(value: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for byte in value.bytes() {
        if let Some(active) = quote {
            if escaped {
                current.push(byte as char);
                escaped = false;
            } else if active == b'"' && byte == b'\\' {
                escaped = true;
            } else if byte == active {
                quote = None;
            } else {
                current.push(byte as char);
            }
        } else if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
        } else if byte.is_ascii_whitespace() || byte == b',' {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(byte as char);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

fn matching_paren(source: &str, open: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut quote = None;
    let mut escaped = false;
    for (index, byte) in source.bytes().enumerate().skip(open) {
        if let Some(active) = quote {
            if active == b'"' && escaped {
                escaped = false;
            } else if active == b'"' && byte == b'\\' {
                escaped = true;
            } else if byte == active {
                quote = None;
            }
            continue;
        }
        if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
        } else if byte == b'(' {
            depth += 1;
        } else if byte == b')' {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}
