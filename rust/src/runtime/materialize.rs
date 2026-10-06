use super::types::ResolvedRunner;
#[cfg(unix)]
use crate::paths::quote_shell_arg;
use crate::paths::{basename, dirname, extension, file_name_without_extension};

pub fn materialize_runner(runner: &mut ResolvedRunner, path: &str) -> Result<(), String> {
    if let Some(cwd) = runner.cwd.take() {
        runner.cwd = Some(substitute(&cwd, path, false, None));
    }
    let cwd_hint = runner.cwd.clone();
    if let Some(cleanup) = runner.cleanup_command.take() {
        runner.cleanup_command = Some(substitute(&cleanup, path, true, cwd_hint.as_deref()));
    }
    if let Some(command) = runner.command.take() {
        let command = substitute(&command, path, true, cwd_hint.as_deref());
        if is_reserved_argv_command(&command) {
            return Err("ReservedRunResolveArgvCommand".to_owned());
        }
        runner.argv = tokenize_command(&command)?;
        runner.command = Some(command);
    } else {
        runner.argv = runner
            .argv
            .iter()
            .map(|arg| substitute(arg, path, false, None))
            .collect();
    }
    Ok(())
}

pub fn substitute_variables_raw(value: &str, path: &str) -> String {
    substitute(value, path, false, None)
}

pub fn substitute_variables_shell(value: &str, path: &str) -> String {
    substitute(value, path, true, None)
}

pub fn tokenize_command(command: &str) -> Result<Vec<String>, String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in command.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            escaped = true;
            continue;
        }
        if let Some(active) = quote {
            if character == active {
                quote = None;
            } else {
                current.push(character);
            }
            continue;
        }
        match character {
            '\'' | '"' => quote = Some(character),
            value if value.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            value => current.push(value),
        }
    }
    if escaped || quote.is_some() {
        return Err("UnterminatedCommandQuote".to_owned());
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    Ok(tokens)
}

pub(crate) fn first_external_program(command: &str) -> Option<String> {
    let tokens = tokenize_command(command).ok()?;
    let mut at_segment_start = true;
    for token in tokens {
        if matches!(token.as_str(), "&&" | "||" | ";" | "|" | "&") {
            at_segment_start = true;
            continue;
        }
        if !at_segment_start {
            continue;
        }
        at_segment_start = false;
        if is_shell_builtin(&token) {
            continue;
        }
        return Some(token);
    }
    None
}

fn is_shell_builtin(command: &str) -> bool {
    #[cfg(windows)]
    {
        return matches!(
            command,
            "call"
                | "cd"
                | "chcp"
                | "cls"
                | "color"
                | "copy"
                | "del"
                | "dir"
                | "echo"
                | "endlocal"
                | "erase"
                | "exit"
                | "for"
                | "goto"
                | "if"
                | "md"
                | "mkdir"
                | "move"
                | "path"
                | "pause"
                | "prompt"
                | "rd"
                | "ren"
                | "rmdir"
                | "set"
                | "setlocal"
                | "shift"
                | "start"
                | "title"
                | "type"
                | "ver"
                | "vol"
        );
    }
    #[cfg(not(windows))]
    {
        matches!(
            command,
            "." | "["
                | ":"
                | "alias"
                | "cd"
                | "declare"
                | "echo"
                | "eval"
                | "exec"
                | "exit"
                | "export"
                | "false"
                | "local"
                | "printf"
                | "pwd"
                | "read"
                | "return"
                | "set"
                | "shift"
                | "source"
                | "test"
                | "true"
                | "type"
                | "ulimit"
                | "umask"
                | "unalias"
                | "unset"
                | "wait"
        )
    }
}

fn substitute(value: &str, path: &str, shell: bool, cwd_hint: Option<&str>) -> String {
    let dir = dirname(path);
    let root = cwd_hint.unwrap_or(dir);

    let mut output = String::with_capacity(value.len());
    let mut quote = None;
    let mut index = 0;
    while index < value.len() {
        let character = value[index..]
            .chars()
            .next()
            .expect("index always points at a character boundary");
        if shell && character == '\\' {
            output.push(character);
            index += character.len_utf8();
            if index < value.len() {
                let escaped = value[index..]
                    .chars()
                    .next()
                    .expect("index always points at a character boundary");
                output.push(escaped);
                index += escaped.len_utf8();
            }
            continue;
        }
        if character == '%' && value[index + character.len_utf8()..].starts_with('%') {
            output.push('%');
            index += character.len_utf8() + 1;
            continue;
        }
        if character != '$' {
            output.push(character);
            if shell {
                if let Some(active) = quote {
                    if character == active {
                        quote = None;
                    }
                } else if character == '\'' || character == '"' {
                    quote = Some(character);
                }
            }
            index += character.len_utf8();
            continue;
        }

        let name_start = index + 1;
        let mut end = name_start;
        while end < value.len()
            && (value.as_bytes()[end].is_ascii_alphanumeric() || value.as_bytes()[end] == b'_')
        {
            end += 1;
        }
        if end == name_start {
            output.push('$');
            index += 1;
            continue;
        }

        let name = &value[name_start..end];
        let replacement = if name.eq_ignore_ascii_case("dir") {
            Some(dir)
        } else if name.eq_ignore_ascii_case("file") {
            Some(path)
        } else if name.eq_ignore_ascii_case("filename") {
            Some(basename(path))
        } else if name.eq_ignore_ascii_case("filenamewithoutext") {
            Some(file_name_without_extension(path))
        } else if name.eq_ignore_ascii_case("fileext") {
            Some(extension(path))
        } else if name.eq_ignore_ascii_case("dirname") {
            Some(basename(root))
        } else {
            None
        };

        if let Some(replacement) = replacement {
            if shell {
                append_shell_value(&mut output, replacement, quote);
            } else {
                output.push_str(replacement);
            }
        } else {
            output.push_str(&value[index..end]);
        }
        index = end;
    }
    output
}

fn append_shell_value(output: &mut String, value: &str, quote: Option<char>) {
    #[cfg(unix)]
    {
        match quote {
            Some('\'') => output.push_str(&value.replace('\'', "'\"'\"'")),
            Some('"') => {
                for character in value.chars() {
                    if matches!(character, '\\' | '"' | '$' | '`') {
                        output.push('\\');
                    }
                    output.push(character);
                }
            }
            None => output.push_str(&quote_shell_arg(value)),
            _ => unreachable!(),
        }
    }
    #[cfg(windows)]
    {
        if quote == Some('"') {
            for character in value.chars() {
                if character == '"' {
                    output.push_str("^\"");
                } else if character == '\\' {
                    output.push('/');
                } else {
                    output.push(character);
                }
            }
        } else {
            output.push('"');
            for character in value.chars() {
                if character == '"' {
                    output.push_str("^\"");
                } else if character == '\\' {
                    output.push('/');
                } else {
                    output.push(character);
                }
            }
            output.push('"');
        }
    }
}

fn is_reserved_argv_command(command: &str) -> bool {
    let trimmed = command.trim_start();
    trimmed == "--argv" || trimmed.starts_with("--argv ") || trimmed.starts_with("--argv\t")
}

#[cfg(test)]
mod tests {
    use super::first_external_program;

    #[test]
    fn executable_lookup_skips_shell_builtins_and_checks_later_commands() {
        assert_eq!(
            first_external_program("cd /tmp && echo ready && cargo test"),
            Some("cargo".to_owned())
        );
        assert_eq!(first_external_program("echo ready"), None);
        assert_eq!(
            first_external_program("cargo test"),
            Some("cargo".to_owned())
        );
    }
}
