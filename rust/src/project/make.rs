use super::common::{invalid_payload, push_command, shell_token};
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(root: ProjectRoot, kind: ProjectKind) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    let mut project = Project::new(root, kind);
    for raw_line in contents.lines() {
        if raw_line.starts_with('\t') {
            continue;
        }
        let line = strip_comment(raw_line).trim();
        if line.is_empty() || line.starts_with('#') || line.contains("CMAKE generated file") {
            continue;
        }
        let Some(colon) = line.find(':') else {
            continue;
        };
        let (left, right) = line.split_at(colon);
        let target_text = if left.trim() == ".PHONY" {
            right[1..].trim()
        } else {
            left.trim()
        };
        for target in target_text.split_whitespace() {
            let target = target.trim_matches('\\');
            if !valid_make_target(target) || invalid_payload(target) {
                continue;
            }
            let quoted = shell_token(target);
            push_command(&mut project.commands, target, &format!("make {quoted}"));
        }
    }
    Ok(project)
}

fn strip_comment(value: &str) -> &str {
    let mut escaped = false;
    for (index, byte) in value.bytes().enumerate() {
        if byte == b'#' && !escaped {
            return &value[..index];
        }
        escaped = byte == b'\\' && !escaped;
        if byte != b'\\' {
            escaped = false;
        }
    }
    value
}

fn valid_make_target(value: &str) -> bool {
    !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || matches!(character, '_' | '-' | '.' | '/' | '%' | '@' | '+' | ':')
        })
}
