use super::types::TailOutput;

pub fn tail_output(input: &[u8], max_bytes: usize) -> TailOutput {
    let mut lines = Vec::new();
    let mut total_bytes = 0usize;
    let mut start_index = 0usize;
    let mut truncated = false;

    for raw_line in input.split(|byte| *byte == b'\n') {
        let line = raw_line.strip_suffix(b"\r").unwrap_or(raw_line);
        if line.is_empty() {
            continue;
        }
        lines.push(line.to_vec());
        total_bytes = total_bytes.saturating_add(line.len().saturating_add(1));

        while total_bytes > max_bytes && start_index + 1 < lines.len() {
            let removed = lines[start_index].len().saturating_add(1);
            total_bytes = total_bytes.saturating_sub(removed);
            start_index += 1;
            truncated = true;
        }
        if total_bytes > max_bytes {
            truncated = true;
        }
    }

    if lines.is_empty() && !input.is_empty() {
        truncated = true;
    }
    if start_index > 0 {
        lines = lines.split_off(start_index);
    }
    TailOutput { lines, truncated }
}
