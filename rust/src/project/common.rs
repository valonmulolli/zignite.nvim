use super::core::{ProjectCommand, ProjectError};
use crate::paths::quote_shell_arg;
use std::path::Path;

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
    for character in value.chars() {
        if comment {
            if character == '\n' {
                comment = false;
                result.push('\n');
            } else {
                result.push(' ');
            }
            continue;
        }
        if let Some(active) = quote {
            result.push(character);
            if active == '"' && escaped {
                escaped = false;
            } else if active == '"' && character == '\\' {
                escaped = true;
            } else if character == active {
                quote = None;
            }
            continue;
        }
        if character == '"' || character == '\'' {
            quote = Some(character);
            result.push(character);
        } else if character == '#' {
            comment = true;
            result.push(' ');
        } else {
            result.push(character);
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
        let character = source[offset..]
            .chars()
            .next()
            .expect("offset is within the source");
        let next_offset = offset + character.len_utf8();
        if let Some(active) = quote {
            if active == '"' && escaped {
                escaped = false;
            } else if active == '"' && character == '\\' {
                escaped = true;
            } else if character == active {
                quote = None;
            }
            offset = next_offset;
            continue;
        }
        if character == '"' || character == '\'' {
            quote = Some(character);
            offset = next_offset;
            continue;
        }
        if source[offset..].starts_with(name)
            && source[..offset]
                .chars()
                .next_back()
                .is_none_or(|previous| !previous.is_ascii_alphanumeric() && previous != '_')
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
        offset = next_offset;
    }
    result
}

pub fn tokenize(value: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in value.chars() {
        if let Some(active) = quote {
            if escaped {
                current.push(character);
                escaped = false;
            } else if active == '"' && character == '\\' {
                escaped = true;
            } else if character == active {
                quote = None;
            } else {
                current.push(character);
            }
        } else if character == '"' || character == '\'' {
            quote = Some(character);
        } else if character.is_ascii_whitespace() || character == ',' {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(character);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

pub(crate) fn discovered_build_dir(root: &Path, marker: &str) -> (String, bool) {
    for candidate in ["build", "build-debug", "build-release"] {
        if root.join(candidate).join(marker).is_file() {
            return (candidate.to_owned(), true);
        }
    }
    let Ok(entries) = std::fs::read_dir(root) else {
        return ("build".to_owned(), false);
    };
    let mut directories = entries
        .flatten()
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    directories.sort();
    for path in directories {
        if path.is_dir() && path.join(marker).is_file() {
            if let Some(name) = path.file_name().and_then(|name| name.to_str()) {
                return (name.to_owned(), true);
            }
        }
    }
    ("build".to_owned(), false)
}

pub(crate) fn shell_word(value: &str) -> String {
    if value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"._/-:".contains(&byte))
    {
        value.to_owned()
    } else {
        quote_shell_arg(value)
    }
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
