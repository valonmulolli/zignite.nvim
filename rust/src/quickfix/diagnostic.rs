pub fn parse_diagnostic(line: &[u8]) -> Option<String> {
    let mut line = std::str::from_utf8(line).ok()?.trim();
    if line.is_empty() {
        return None;
    }
    if let Some(rest) = line.strip_prefix("-->") {
        line = rest.trim();
    }
    parse_parenthesized(line).or_else(|| parse_colon(line))
}

fn parse_colon(line: &str) -> Option<String> {
    let bytes = line.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b':' {
            continue;
        }
        let line_start = index + 1;
        let mut cursor = line_start;
        while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
            cursor += 1;
        }
        if cursor == line_start || cursor >= bytes.len() || bytes[cursor] != b':' {
            continue;
        }
        let path = line[..index].trim();
        if !plausible_path(path) {
            continue;
        }
        let line_number = line[line_start..cursor].parse::<usize>().ok()?;
        let after_line = cursor + 1;
        let mut column_cursor = after_line;
        while column_cursor < bytes.len() && bytes[column_cursor].is_ascii_digit() {
            column_cursor += 1;
        }
        let (column, message_start) = if column_cursor > after_line
            && column_cursor < bytes.len()
            && bytes[column_cursor] == b':'
        {
            (
                line[after_line..column_cursor]
                    .parse::<usize>()
                    .unwrap_or(1),
                column_cursor + 1,
            )
        } else {
            (1, after_line)
        };
        let message = line[message_start..].trim();
        return Some(format!(
            "{path}:{line_number}:{column}: {}",
            if message.is_empty() {
                "diagnostic"
            } else {
                message
            }
        ));
    }
    None
}

fn parse_parenthesized(line: &str) -> Option<String> {
    let open = line.find('(')?;
    let close = line[open + 1..].find(')')? + open + 1;
    let prefix = line[..open].trim();
    let location = line[open + 1..close].trim();
    let (path, line_number, column) =
        if let Some((path, line_number, column)) = parse_location_suffix(location) {
            if !plausible_path(path) {
                return None;
            }
            (path, line_number, column)
        } else {
            let (line_number, column) = parse_line_column(location)?;
            if !plausible_path(prefix) {
                return None;
            }
            (prefix, line_number, column)
        };
    let message = line[close + 1..].trim();
    Some(format!(
        "{path}:{line_number}:{column}: {}",
        if message.is_empty() {
            "diagnostic"
        } else {
            message
        }
    ))
}

fn parse_location_suffix(value: &str) -> Option<(&str, usize, usize)> {
    let (line_and_path, column) = value.rsplit_once(':')?;
    let column = column.parse().ok()?;
    let (path, line_number) = line_and_path.rsplit_once(':')?;
    let line_number = line_number.parse().ok()?;
    Some((path.trim(), line_number, column))
}

fn parse_line_column(value: &str) -> Option<(usize, usize)> {
    let (line_number, column) = value.split_once(':')?;
    Some((
        line_number.trim().parse().ok()?,
        column.trim().parse().ok()?,
    ))
}

fn plausible_path(path: &str) -> bool {
    let path = path.trim();
    if path.is_empty() || !path.bytes().any(|byte| matches!(byte, b'/' | b'\\' | b'.')) {
        return false;
    }
    if !path.contains(char::is_whitespace) {
        return true;
    }
    path.starts_with('/')
        || path.starts_with("./")
        || path.starts_with("../")
        || path.as_bytes().get(1) == Some(&b':')
}
