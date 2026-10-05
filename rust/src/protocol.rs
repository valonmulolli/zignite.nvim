use std::fmt;
use std::io::{BufRead, Write};

pub const DEFAULT_MAX_LINE: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RequestId(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub marker: String,
    pub id: RequestId,
    pub body: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ProtocolError {
    Io(String),
    LineTooLong { limit: usize },
    InvalidUtf8,
    InvalidMarker,
    InvalidRequestId,
    ControlCharacter,
    MalformedHeader,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(message) => write!(formatter, "I/O error: {message}"),
            Self::LineTooLong { limit } => write!(formatter, "line exceeds {limit} bytes"),
            Self::InvalidUtf8 => formatter.write_str("line is not valid UTF-8"),
            Self::InvalidMarker => formatter.write_str("invalid protocol marker"),
            Self::InvalidRequestId => formatter.write_str("invalid request id"),
            Self::ControlCharacter => formatter.write_str("control character in protocol value"),
            Self::MalformedHeader => formatter.write_str("malformed protocol header"),
        }
    }
}

impl std::error::Error for ProtocolError {}

/// Reads one bounded UTF-8 protocol line without its line ending.
pub fn read_line_limited<R: BufRead>(
    reader: &mut R,
    limit: usize,
) -> Result<Option<String>, ProtocolError> {
    let mut bytes = Vec::new();
    let read = reader
        .read_until(b'\n', &mut bytes)
        .map_err(|error| ProtocolError::Io(error.to_string()))?;
    if read == 0 {
        return Ok(None);
    }
    if bytes.len() > limit {
        return Err(ProtocolError::LineTooLong { limit });
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| ProtocolError::InvalidUtf8)
}

/// Matches a marker only at the start of a line and only at a token boundary.
pub fn has_marker_prefix(line: &str, marker: &str) -> bool {
    if !line.starts_with(marker) {
        return false;
    }
    match line.as_bytes().get(marker.len()) {
        None => true,
        Some(byte) => byte.is_ascii_whitespace(),
    }
}

pub fn parse_request_id(line: &str, marker: &str) -> Option<RequestId> {
    if !has_marker_prefix(line, marker) {
        return None;
    }
    let mut fields = line.split_whitespace();
    if fields.next()? != marker {
        return None;
    }
    Some(RequestId(fields.next()?.parse().ok()?))
}

pub struct ResponseFrame<'a> {
    pub begin_marker: &'a str,
    pub error_marker: &'a str,
    pub end_marker: &'a str,
    pub id: RequestId,
    pub body: &'a [String],
    pub error: Option<&'a str>,
}

impl<'a> ResponseFrame<'a> {
    pub fn success(
        begin_marker: &'a str,
        end_marker: &'a str,
        id: RequestId,
        body: &'a [String],
    ) -> Self {
        Self {
            begin_marker,
            error_marker: "",
            end_marker,
            id,
            body,
            error: None,
        }
    }

    pub fn failure(
        begin_marker: &'a str,
        error_marker: &'a str,
        end_marker: &'a str,
        id: RequestId,
        error: &'a str,
    ) -> Self {
        Self {
            begin_marker,
            error_marker,
            end_marker,
            id,
            body: &[],
            error: Some(error),
        }
    }
}

pub fn write_response<W: Write>(
    writer: &mut W,
    response: ResponseFrame<'_>,
) -> Result<(), ProtocolError> {
    validate_marker(response.begin_marker)?;
    validate_marker(response.end_marker)?;
    if response.error.is_some() {
        validate_marker(response.error_marker)?;
    }

    writeln!(writer, "{} {}", response.begin_marker, response.id.0)
        .map_err(|error| ProtocolError::Io(error.to_string()))?;
    if let Some(error) = response.error {
        validate_value(error)?;
        writeln!(
            writer,
            "{} {} {}",
            response.error_marker, response.id.0, error
        )
        .map_err(|io_error| ProtocolError::Io(io_error.to_string()))?;
    } else {
        for value in response.body {
            validate_value(value)?;
            writeln!(writer, "\t{value}").map_err(|error| ProtocolError::Io(error.to_string()))?;
        }
    }
    writeln!(writer, "{} {}", response.end_marker, response.id.0)
        .map_err(|error| ProtocolError::Io(error.to_string()))?;
    writer
        .flush()
        .map_err(|error| ProtocolError::Io(error.to_string()))
}

fn validate_marker(marker: &str) -> Result<(), ProtocolError> {
    if marker.is_empty()
        || !marker.starts_with("@@")
        || marker
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
    {
        return Err(ProtocolError::InvalidMarker);
    }
    Ok(())
}

fn validate_value(value: &str) -> Result<(), ProtocolError> {
    if value
        .bytes()
        .any(|byte| byte.is_ascii_control() && byte != b'\t')
    {
        return Err(ProtocolError::ControlCharacter);
    }
    Ok(())
}
