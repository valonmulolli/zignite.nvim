use std::path::Path;

pub fn normalize_path(value: &str) -> String {
    if value.is_empty() {
        return String::new();
    }
    let separator = if value.contains('\\') && !value.contains('/') {
        '\\'
    } else {
        '/'
    };
    let absolute = value.starts_with('/') || value.starts_with('\\') || is_drive_root(value);
    let prefix_len = if value.starts_with("//") || value.starts_with(r"\\") {
        2
    } else if is_drive_root(value) {
        3.min(value.len())
    } else if absolute {
        1
    } else {
        0
    };
    let prefix = if is_drive_root(value) {
        value[..2].to_owned()
    } else if prefix_len == 2 {
        separator.to_string().repeat(2)
    } else if absolute {
        separator.to_string()
    } else {
        String::new()
    };

    let mut parts = Vec::new();
    for part in value[prefix_len..].split(['/', '\\']) {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            if parts.last().is_some_and(|part: &&str| *part != "..") {
                parts.pop();
            } else if !absolute {
                parts.push(part);
            }
            continue;
        }
        parts.push(part);
    }

    let joined = parts.join(&separator.to_string());
    if prefix.is_empty() {
        return joined;
    }
    if joined.is_empty() {
        return prefix;
    }
    if is_drive_root(value) {
        format!("{prefix}{separator}{joined}")
    } else {
        format!("{prefix}{joined}")
    }
}

pub fn quote_shell_arg(value: &str) -> String {
    #[cfg(unix)]
    {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
    #[cfg(windows)]
    {
        let mut quoted = String::from("\"");
        let mut backslashes = 0;
        for character in value.chars() {
            if character == '\\' {
                backslashes += 1;
            } else if character == '"' {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push(character);
                backslashes = 0;
            } else {
                quoted.push_str(&"\\".repeat(backslashes));
                quoted.push(character);
                backslashes = 0;
            }
        }
        quoted.push_str(&"\\".repeat(backslashes * 2));
        quoted.push('"');
        quoted
    }
}

pub fn basename(value: &str) -> &str {
    value.rsplit(['/', '\\']).next().unwrap_or(value)
}

pub fn dirname(value: &str) -> &str {
    let Some(index) = value.rfind(['/', '\\']) else {
        return ".";
    };
    if index == 0 {
        return &value[..1];
    }
    &value[..index]
}

pub fn extension(value: &str) -> &str {
    let base = basename(value);
    let Some(index) = base.rfind('.') else {
        return "";
    };
    if index == 0 {
        return "";
    }
    &base[index + 1..]
}

pub fn file_name_without_extension(value: &str) -> &str {
    let base = basename(value);
    let ext = extension(value);
    if ext.is_empty() {
        return base;
    }
    &base[..base.len() - ext.len() - 1]
}

pub fn path_exists(value: &str) -> bool {
    Path::new(value).exists()
}

fn is_drive_root(value: &str) -> bool {
    value.len() >= 3
        && value.as_bytes()[0].is_ascii_alphabetic()
        && value.as_bytes()[1] == b':'
        && matches!(value.as_bytes()[2], b'/' | b'\\')
}
