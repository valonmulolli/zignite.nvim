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
