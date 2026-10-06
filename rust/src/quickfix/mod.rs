pub mod ansi;
pub mod diagnostic;
pub mod tail;
pub mod types;

use std::io::{self, BufRead, Read, Write};

use crate::error::BackendError;
use crate::protocol::{
    has_marker_prefix, parse_request_id, read_line_limited, write_response, RequestId,
    ResponseFrame, DEFAULT_MAX_LINE,
};
pub use ansi::strip_ansi;
pub use diagnostic::parse_diagnostic;
pub use tail::tail_output;
pub use types::{
    parse_bool, parse_nonzero, parse_options, QuickfixOptions, QuickfixResult, TailOutput,
};

pub const QUICKFIX_REQ_BEGIN: &str = "@@ZQF_BEGIN";
pub const QUICKFIX_REQ_END: &str = "@@ZQF_END";
pub const QUICKFIX_RES_BEGIN: &str = "@@ZQF_RES_BEGIN";
pub const QUICKFIX_RES_ERR: &str = "@@ZQF_RES_ERR";
pub const QUICKFIX_RES_END: &str = "@@ZQF_RES_END";
pub const QUICKFIX_MAX_INPUT_BYTES: usize = 16 * 1024 * 1024;

pub fn process_quickfix(
    input: &[u8],
    options: QuickfixOptions,
    already_truncated: bool,
) -> QuickfixResult {
    let tail = tail::tail_output(input, options.max_bytes);
    let max_lines = options.max_lines.max(1);
    let overflow_lines = tail.lines.len() > max_lines;
    let start_index = if overflow_lines {
        tail.lines.len() - max_lines
    } else {
        0
    };
    let final_count = tail.lines.len() - start_index;
    let truncated = already_truncated || tail.truncated || overflow_lines;

    let mut lines = Vec::with_capacity(final_count + usize::from(truncated));
    if truncated {
        lines.push("[zignite] quickfix output truncated".to_owned());
    }

    let strip_enabled = options.strip_ansi && options.strip_max_lines > 0;
    let strip_from_index = if strip_enabled {
        if options.strip_max_lines >= final_count {
            start_index
        } else {
            tail.lines.len().saturating_sub(options.strip_max_lines)
        }
    } else {
        tail.lines.len()
    };

    for (index, original_line) in tail.lines.iter().enumerate().skip(start_index) {
        let stripped;
        let line = if index >= strip_from_index {
            stripped = ansi::strip_ansi(original_line);
            stripped.as_slice()
        } else {
            original_line.as_slice()
        };
        let text = String::from_utf8_lossy(line);
        if options.parse_diagnostics {
            if let Some(diagnostic) = diagnostic::parse_diagnostic(line) {
                lines.push(diagnostic);
                continue;
            }
        }
        lines.push(text.into_owned());
    }

    QuickfixResult { lines, truncated }
}

pub fn read_bounded<R: Read>(reader: &mut R) -> Result<Vec<u8>, String> {
    let mut input = Vec::new();
    let limit = QUICKFIX_MAX_INPUT_BYTES + 1;
    reader
        .take(limit as u64)
        .read_to_end(&mut input)
        .map_err(|error| format!("QuickfixInputRead: {error}"))?;
    if input.len() > QUICKFIX_MAX_INPUT_BYTES {
        return Err("QuickfixInputTooLarge".to_owned());
    }
    Ok(input)
}

pub fn write_processed<W: Write>(writer: &mut W, result: &QuickfixResult) -> io::Result<()> {
    for line in &result.lines {
        writer.write_all(line.as_bytes())?;
        writer.write_all(b"\n")?;
    }
    writer.flush()
}

pub fn run_daemon<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
) -> Result<(), BackendError> {
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if has_marker_prefix(&line, QUICKFIX_REQ_BEGIN) {
            handle_frame(reader, writer, &line)?;
        } else if !line.trim().is_empty() {
            return Err(crate::protocol::ProtocolError::MalformedHeader.into());
        }
    }
    Ok(())
}

pub fn handle_frame<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    begin_line: &str,
) -> Result<(), BackendError> {
    let request_id = parse_request_id(begin_line, QUICKFIX_REQ_BEGIN);
    let header = match parse_header(begin_line) {
        Ok(header) => header,
        Err(error) => {
            if let Some(id) = request_id {
                discard_until_end(reader, id)?;
                write_error(writer, id, error)?;
                return Ok(());
            }
            return Err(crate::protocol::ProtocolError::MalformedHeader.into());
        }
    };

    let end_marker = format!("{QUICKFIX_REQ_END} {}", header.0 .0);
    let mut input = Vec::new();
    let mut completed = false;
    let mut payload_error = None;
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            completed = true;
            break;
        }
        if payload_error.is_some() {
            continue;
        }
        let content = line.strip_prefix('\t').unwrap_or(&line);
        let line_size = content.len().saturating_add(1);
        if input.len().saturating_add(line_size) > QUICKFIX_MAX_INPUT_BYTES {
            payload_error = Some("QuickfixInputTooLarge");
            continue;
        }
        input.extend_from_slice(content.as_bytes());
        input.push(b'\n');
    }

    if !completed {
        return write_error(writer, header.0, "UnexpectedEof");
    }
    if let Some(error) = payload_error {
        return write_error(writer, header.0, error);
    }

    let result = process_quickfix(&input, header.1, false);
    let body = result.lines;
    write_response(
        writer,
        ResponseFrame::success(QUICKFIX_RES_BEGIN, QUICKFIX_RES_END, header.0, &body),
    )?;
    Ok(())
}

fn parse_header(line: &str) -> Result<(RequestId, QuickfixOptions), &'static str> {
    let mut fields = line.split_whitespace();
    if fields.next() != Some(QUICKFIX_REQ_BEGIN) {
        return Err("InvalidQuickfixHeader");
    }
    let request_id = fields
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .map(RequestId)
        .ok_or("InvalidQuickfixHeader")?;
    let max_lines = fields
        .next()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.max(1))
        .ok_or("InvalidQuickfixHeader")?;
    let max_bytes = fields
        .next()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.max(1))
        .ok_or("InvalidQuickfixHeader")?;
    let strip_ansi = parse_protocol_bool(fields.next().ok_or("InvalidQuickfixHeader")?)?;
    let strip_max_lines = fields
        .next()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.max(1))
        .ok_or("InvalidQuickfixHeader")?;
    let parse_diagnostics = parse_protocol_bool(fields.next().ok_or("InvalidQuickfixHeader")?)?;
    if fields.next().is_some() {
        return Err("InvalidQuickfixHeader");
    }
    Ok((
        request_id,
        QuickfixOptions {
            max_lines,
            max_bytes,
            strip_ansi,
            strip_max_lines,
            parse_diagnostics,
        },
    ))
}

fn parse_protocol_bool(value: &str) -> Result<bool, &'static str> {
    match value {
        "1" => Ok(true),
        "0" => Ok(false),
        _ => Err("InvalidQuickfixHeader"),
    }
}

fn discard_until_end<R: BufRead>(
    reader: &mut R,
    request_id: RequestId,
) -> Result<(), BackendError> {
    let end_marker = format!("{QUICKFIX_REQ_END} {}", request_id.0);
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            break;
        }
    }
    Ok(())
}

fn write_error<W: Write>(
    writer: &mut W,
    request_id: RequestId,
    error: &str,
) -> Result<(), BackendError> {
    write_response(
        writer,
        ResponseFrame::failure(
            QUICKFIX_RES_BEGIN,
            QUICKFIX_RES_ERR,
            QUICKFIX_RES_END,
            request_id,
            error,
        ),
    )?;
    Ok(())
}
