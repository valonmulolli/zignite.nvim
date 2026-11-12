pub fn contains_main_function(source: &str) -> bool {
    contains_function(source, "main")
}

pub fn contains_test_declaration(source: &str) -> bool {
    let clean = strip_comments_and_strings(source);
    let bytes = clean.as_bytes();
    let mut index = 0;
    while index + 4 <= bytes.len() {
        if &bytes[index..index + 4] == b"test"
            && boundary(bytes, index, 4)
            && clean[index + 4..].trim_start().starts_with('"')
        {
            return true;
        }
        index += 1;
    }
    false
}

pub fn contains_build_module_import(source: &str) -> bool {
    let bytes = source.as_bytes();
    let mut index = 0;
    let mut line_start = true;
    while index < bytes.len() {
        if bytes[index] == b'\n' {
            index += 1;
            line_start = true;
            continue;
        }
        if line_start && matches!(bytes[index], b' ' | b'\t' | b'\r') {
            index += 1;
            continue;
        }
        if line_start && bytes[index..].starts_with(b"\\\\") {
            index = skip_line(bytes, index);
            line_start = false;
            continue;
        }
        line_start = false;
        if bytes[index..].starts_with(b"//") {
            index = skip_line(bytes, index);
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            (index, line_start) = skip_block_comment(bytes, index);
            continue;
        }
        if matches!(bytes[index], b'"' | b'\'') {
            index = skip_quoted(bytes, index, bytes[index]);
            continue;
        }
        if source[index..].starts_with("@import")
            && (index == 0 || !is_identifier(bytes[index - 1]))
        {
            let after_name = index + "@import".len();
            if after_name == bytes.len() || !is_identifier(bytes[after_name]) {
                if let Some((name, end)) = parse_import_string(source, after_name) {
                    if !matches!(name, "std" | "builtin" | "root") && !name.ends_with(".zig") {
                        return true;
                    }
                    index = end;
                    continue;
                }
            }
        }
        index += source[index..]
            .chars()
            .next()
            .expect("index is within the source")
            .len_utf8();
    }
    false
}

pub fn contains_named_build_step(source: &str, name: &str) -> bool {
    let bytes = source.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index..].starts_with(b"//") {
            index = skip_line(bytes, index);
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            index = skip_block_comment(bytes, index).0;
            continue;
        }
        if matches!(bytes[index], b'"' | b'\'') {
            index = skip_quoted(bytes, index, bytes[index]);
            continue;
        }
        if bytes[index..].starts_with(b"step")
            && (index == 0 || !is_identifier(bytes[index - 1]))
            && (index + 4 == bytes.len() || !is_identifier(bytes[index + 4]))
            && previous_non_whitespace(bytes, index) == Some(b'.')
        {
            if named_step_call(source, index + 4, name).is_some() {
                return true;
            } else {
                index += 4;
                continue;
            }
        }
        index += source[index..]
            .chars()
            .next()
            .expect("index is within the source")
            .len_utf8();
    }
    false
}

fn previous_non_whitespace(bytes: &[u8], mut index: usize) -> Option<u8> {
    while index > 0 {
        index -= 1;
        if !bytes[index].is_ascii_whitespace() {
            return Some(bytes[index]);
        }
    }
    None
}

fn named_step_call(source: &str, mut index: usize, name: &str) -> Option<usize> {
    let bytes = source.as_bytes();
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    if bytes.get(index) != Some(&b'(') {
        return None;
    }
    index += 1;
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    if bytes.get(index) != Some(&b'"') {
        return None;
    }
    index += 1;
    let end = index.checked_add(name.len())?;
    if source.get(index..end)? != name || bytes.get(end) != Some(&b'"') {
        return None;
    }
    index = end + 1;
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    matches!(bytes.get(index), Some(b',' | b')')).then_some(index)
}

fn parse_import_string(source: &str, mut index: usize) -> Option<(&str, usize)> {
    let bytes = source.as_bytes();
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    if bytes.get(index) != Some(&b'(') {
        return None;
    }
    index += 1;
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    if bytes.get(index) != Some(&b'"') {
        return None;
    }
    let start = index + 1;
    index = start;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => return None,
            b'"' => return Some((&source[start..index], index + 1)),
            _ => {
                index += source[index..]
                    .chars()
                    .next()
                    .expect("index is within the source")
                    .len_utf8();
            }
        }
    }
    None
}

fn skip_line(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() && bytes[index] != b'\n' {
        index += 1;
    }
    index
}

fn skip_quoted(bytes: &[u8], mut index: usize, quote: u8) -> usize {
    index += 1;
    while index < bytes.len() {
        if bytes[index] == b'\\' {
            index = (index + 2).min(bytes.len());
        } else if bytes[index] == quote {
            return index + 1;
        } else {
            index += 1;
        }
    }
    index
}

fn skip_block_comment(bytes: &[u8], mut index: usize) -> (usize, bool) {
    let mut depth = 1usize;
    let mut line_start = false;
    index += 2;
    while index < bytes.len() && depth > 0 {
        if bytes[index..].starts_with(b"/*") {
            depth += 1;
            index += 2;
        } else if bytes[index..].starts_with(b"*/") {
            depth -= 1;
            index += 2;
        } else {
            line_start = bytes[index] == b'\n';
            index += 1;
        }
    }
    (index, line_start)
}

pub fn contains_function(source: &str, name: &str) -> bool {
    let clean = strip_comments_and_strings(source);
    let bytes = clean.as_bytes();
    let needle = format!("fn {name}");
    let mut start = 0;
    while let Some(offset) = clean[start..].find(&needle) {
        let index = start + offset;
        if boundary(bytes, index, needle.len()) {
            return true;
        }
        start = index + 1;
    }
    false
}

fn boundary(bytes: &[u8], start: usize, length: usize) -> bool {
    let before = start == 0 || !is_identifier(bytes[start - 1]);
    let after = start + length >= bytes.len() || !is_identifier(bytes[start + length]);
    before && after
}

fn is_identifier(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn strip_comments_and_strings(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut output = String::with_capacity(source.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index..].starts_with(b"//") {
            while index < bytes.len() && bytes[index] != b'\n' {
                output.push(' ');
                index += 1;
            }
            continue;
        }
        if bytes[index..].starts_with(b"/*") {
            output.push_str("  ");
            index += 2;
            while index + 1 < bytes.len() && !bytes[index..].starts_with(b"*/") {
                output.push(if bytes[index] == b'\n' { '\n' } else { ' ' });
                index += 1;
            }
            if index + 1 < bytes.len() {
                output.push_str("  ");
                index += 2;
            }
            continue;
        }
        if bytes[index] == b'"' {
            output.push(' ');
            index += 1;
            while index < bytes.len() {
                let character = bytes[index];
                output.push(if character == b'\n' { '\n' } else { ' ' });
                index += 1;
                if character == b'\\' && index < bytes.len() {
                    output.push(' ');
                    index += 1;
                } else if character == b'"' {
                    break;
                }
            }
            continue;
        }
        output.push(bytes[index] as char);
        index += 1;
    }
    output
}

#[cfg(test)]
mod tests {
    use super::contains_named_build_step;

    #[test]
    fn detects_literal_run_step_declarations() {
        assert!(contains_named_build_step(
            "pub fn build(b: *std.Build) void { _ = b.step(\"run\", \"Run app\"); }",
            "run"
        ));
    }

    #[test]
    fn ignores_run_step_text_in_comments_and_strings() {
        let source = r#"
            // b.step("run", "comment only");
            const example = "b.step(\\\"run\\\", \\\"not code\\\");";
            pub fn build(_: *std.Build) void {}
        "#;
        assert!(!contains_named_build_step(source, "run"));
    }

    #[test]
    fn does_not_treat_other_steps_as_run() {
        assert!(!contains_named_build_step(
            "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"Test\"); }",
            "run"
        ));
    }
}
