use std::ffi::OsString;
use std::fmt;
use std::io::{BufRead, Write};
use std::time::Duration;

use crate::error::BackendError;
use crate::process::{run_argv, CommandSpec, ProcessError, TimeoutPolicy};
use crate::protocol::{
    has_marker_prefix, parse_request_id, read_line_limited, write_response, RequestId,
    ResponseFrame, DEFAULT_MAX_LINE,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tool {
    Zig,
    Go,
    Cargo,
    Odin,
    Dart,
    Swift,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedCommand {
    pub name: String,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DetectionError {
    InvalidTool,
    MissingTool { tool: Tool },
    CommandFailed { tool: Tool },
    Process { tool: Tool, message: String },
}

impl DetectionError {
    pub fn missing(tool: Tool) -> Self {
        Self::MissingTool { tool }
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidTool => "InvalidDetectTool",
            Self::MissingTool { .. } => "MissingTool",
            Self::CommandFailed { .. } => "DetectCommandFailed",
            Self::Process { .. } => "DetectProcessError",
        }
    }
}

impl fmt::Display for DetectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidTool => formatter.write_str("invalid detection tool"),
            Self::MissingTool { tool } => write!(formatter, "required tool missing: {tool}"),
            Self::CommandFailed { tool } => write!(formatter, "detection command failed: {tool}"),
            Self::Process { tool, message } => {
                write!(formatter, "detection process failed for {tool}: {message}")
            }
        }
    }
}

impl fmt::Display for Tool {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.name())
    }
}

pub const DETECT_REQ_BEGIN: &str = "@@ZDET_REQ_BEGIN";
pub const DETECT_REQ_END: &str = "@@ZDET_REQ_END";
pub const DETECT_RES_BEGIN: &str = "@@ZDET_RES_BEGIN";
pub const DETECT_RES_ERR: &str = "@@ZDET_RES_ERR";
pub const DETECT_RES_END: &str = "@@ZDET_RES_END";

pub fn parse_tool(value: &str) -> Result<Tool, DetectionError> {
    match value.to_ascii_lowercase().as_str() {
        "zig" => Ok(Tool::Zig),
        "go" => Ok(Tool::Go),
        "cargo" => Ok(Tool::Cargo),
        "odin" => Ok(Tool::Odin),
        "dart" => Ok(Tool::Dart),
        "swift" => Ok(Tool::Swift),
        _ => Err(DetectionError::InvalidTool),
    }
}

impl Tool {
    pub fn name(self) -> &'static str {
        match self {
            Self::Zig => "zig",
            Self::Go => "go",
            Self::Cargo => "cargo",
            Self::Odin => "odin",
            Self::Dart => "dart",
            Self::Swift => "swift",
        }
    }

    pub fn argv(self) -> &'static [&'static str] {
        match self {
            Self::Zig => &["zig", "--help"],
            Self::Go => &["go", "help"],
            Self::Cargo => &["cargo", "--list"],
            Self::Odin => &["odin", "help"],
            Self::Dart => &["dart", "--help"],
            Self::Swift => &["swift", "--help"],
        }
    }
}

pub fn detect_tool(tool: Tool) -> Result<Vec<DetectedCommand>, DetectionError> {
    let spec = CommandSpec {
        argv: tool.argv().iter().map(OsString::from).collect(),
        cwd: None,
        env: Vec::new(),
    };
    let result = run_argv(
        &spec,
        TimeoutPolicy {
            timeout: Some(Duration::from_secs(2)),
            grace: Duration::from_millis(100),
        },
        None,
    )
    .map_err(|error| match error {
        ProcessError::MissingExecutable { .. } => DetectionError::missing(tool),
        other => DetectionError::Process {
            tool,
            message: other.to_string(),
        },
    })?;
    detect_from_output(
        tool,
        &result.stdout,
        &result.stderr,
        result.status.success(),
    )
}

pub fn detect_from_output(
    tool: Tool,
    stdout: &[u8],
    stderr: &[u8],
    successful: bool,
) -> Result<Vec<DetectedCommand>, DetectionError> {
    if !successful {
        return Err(DetectionError::CommandFailed { tool });
    }
    let mut output = Vec::with_capacity(stdout.len().saturating_add(stderr.len() + 1));
    output.extend_from_slice(stdout);
    if !stdout.is_empty() && !stdout.ends_with(b"\n") && !stderr.is_empty() {
        output.push(b'\n');
    }
    output.extend_from_slice(stderr);
    let text = String::from_utf8_lossy(&output);
    let names = parse_command_names(tool, &text);
    Ok(command_records(tool, &names))
}

pub fn parse_command_names(tool: Tool, output: &str) -> Vec<String> {
    let mut commands = Vec::new();
    let mut in_commands_section = false;
    for raw_line in output.lines() {
        let line = raw_line.trim_end_matches('\r');
        let trimmed = line.trim();
        if !in_commands_section {
            let section = match tool {
                Tool::Go => "The commands are:",
                Tool::Cargo => "Installed Commands:",
                Tool::Dart => "Available commands:",
                Tool::Swift => "SUBCOMMANDS:",
                Tool::Zig | Tool::Odin => "Commands:",
            };
            if trimmed == section || (tool == Tool::Swift && trimmed == "Subcommands:") {
                in_commands_section = true;
            }
            continue;
        }

        if section_ended(tool, trimmed) {
            break;
        }
        if matches!(tool, Tool::Odin) && !is_odin_command_entry(line) {
            continue;
        }
        if matches!(tool, Tool::Dart | Tool::Swift) && !is_two_space_entry(line) {
            continue;
        }
        let Some(token) = command_token(trimmed) else {
            continue;
        };
        if matches!(tool, Tool::Go | Tool::Odin) && token == "help" {
            continue;
        }
        if tool == Tool::Cargo && (token.len() <= 1 || cargo_noise(trimmed)) {
            continue;
        }
        let token = if tool == Tool::Swift {
            let Some(token) = trimmed.strip_prefix("swift ") else {
                continue;
            };
            token.split_whitespace().next().unwrap_or(token)
        } else {
            token
        };
        push_unique(&mut commands, token);
    }
    commands
}

pub fn command_records(tool: Tool, names: &[String]) -> Vec<DetectedCommand> {
    names
        .iter()
        .filter(|name| !name.is_empty() && !invalid_payload(name))
        .map(|name| DetectedCommand {
            name: name.clone(),
            command: command_template(tool, name),
        })
        .collect()
}

pub fn run_mode<W: Write>(writer: &mut W, tool: Tool) -> Result<(), BackendError> {
    for command in detect_tool(tool)? {
        writeln!(writer, "{}\t{}", command.name, command.command)?;
    }
    writer.flush()?;
    Ok(())
}

pub fn run_daemon<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
) -> Result<(), BackendError> {
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if has_marker_prefix(&line, DETECT_REQ_BEGIN) {
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
    handle_frame_with(reader, writer, begin_line, detect_tool)
}

pub fn handle_frame_with<R, W, F>(
    reader: &mut R,
    writer: &mut W,
    begin_line: &str,
    detector: F,
) -> Result<(), BackendError>
where
    R: BufRead,
    W: Write,
    F: FnOnce(Tool) -> Result<Vec<DetectedCommand>, DetectionError>,
{
    let request_id = parse_request_id(begin_line, DETECT_REQ_BEGIN);
    let tool = match parse_header(begin_line) {
        Ok(tool) => tool,
        Err(error) => {
            if let Some(id) = request_id {
                discard_until_end(reader, id)?;
                write_error(writer, id, error)?;
                return Ok(());
            }
            return Err(crate::protocol::ProtocolError::MalformedHeader.into());
        }
    };
    let end_marker = format!("{DETECT_REQ_END} {}", request_id.expect("valid header").0);
    let mut completed = false;
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            completed = true;
            break;
        }
    }
    let id = request_id.expect("valid header");
    if !completed {
        return write_error(writer, id, "UnexpectedEof");
    }
    match detector(tool) {
        Ok(commands) => {
            let body = commands
                .into_iter()
                .map(|command| format!("{}\t{}", command.name, command.command))
                .collect::<Vec<_>>();
            write_response(
                writer,
                ResponseFrame::success(DETECT_RES_BEGIN, DETECT_RES_END, id, &body),
            )?;
        }
        Err(error) => write_error(writer, id, error.code())?,
    }
    Ok(())
}

fn parse_header(line: &str) -> Result<Tool, &'static str> {
    let mut fields = line.split_whitespace();
    if fields.next() != Some(DETECT_REQ_BEGIN) || fields.next().is_none() {
        return Err("InvalidDetectHeader");
    }
    let tool = fields.next().ok_or("InvalidDetectHeader")?;
    if fields.next().is_some() {
        return Err("InvalidDetectHeader");
    }
    parse_tool(tool).map_err(|_| "InvalidDetectTool")
}

fn discard_until_end<R: BufRead>(
    reader: &mut R,
    request_id: RequestId,
) -> Result<(), BackendError> {
    let end_marker = format!("{DETECT_REQ_END} {}", request_id.0);
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
            DETECT_RES_BEGIN,
            DETECT_RES_ERR,
            DETECT_RES_END,
            request_id,
            error,
        ),
    )?;
    Ok(())
}

fn section_ended(tool: Tool, line: &str) -> bool {
    match tool {
        Tool::Zig => line == "General Options:",
        Tool::Go => line == "Additional help topics:" || line.starts_with("Use \"go help"),
        Tool::Cargo => false,
        Tool::Odin => {
            line == "Flags:"
                || line == "Example:"
                || line == "Examples:"
                || line.starts_with("For further details on a command")
                || line.starts_with("e.g.")
        }
        Tool::Dart => line.starts_with("Run \"dart help"),
        Tool::Swift => false,
    }
}

fn command_token(line: &str) -> Option<&str> {
    line.split_whitespace().next()
}

fn is_two_space_entry(line: &str) -> bool {
    line.as_bytes().get(0..3).is_some_and(|prefix| {
        prefix[0] == b' ' && prefix[1] == b' ' && prefix[2] != b' ' && prefix[2] != b'\t'
    })
}

fn is_odin_command_entry(line: &str) -> bool {
    if line.as_bytes().first() == Some(&b'\t') {
        return line
            .as_bytes()
            .get(1)
            .is_some_and(|byte| !byte.is_ascii_whitespace());
    }
    is_two_space_entry(line)
}

fn cargo_noise(line: &str) -> bool {
    line.contains("alias:") || line.contains("DEPRECATED:") || line.contains("REMOVED:")
}

fn push_unique(commands: &mut Vec<String>, value: &str) {
    if value.is_empty() || invalid_payload(value) || commands.iter().any(|item| item == value) {
        return;
    }
    commands.push(value.to_owned());
}

fn invalid_payload(value: &str) -> bool {
    value.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
        || [
            "@@ZQF_", "@@ZBR_", "@@ZDET_", "@@ZPRJ_", "@@ZCFG_", "@@ZBA_", "@@ZRUN_", "@@ZHLT_",
        ]
        .iter()
        .any(|prefix| value.contains(prefix))
}

fn command_template(tool: Tool, name: &str) -> String {
    let generic = || format!("{} {}", tool.name(), quote_shell_name(name));
    match tool {
        Tool::Zig => match name {
            "ast-check" => "zig ast-check $file".to_owned(),
            "build" => "zig build".to_owned(),
            "build-exe" => "zig build-exe $file".to_owned(),
            "build-lib" => "zig build-lib $file".to_owned(),
            "build-obj" => "zig build-obj $file".to_owned(),
            "fmt" => "zig fmt $file".to_owned(),
            "run" => "zig run $file".to_owned(),
            "test" => "zig test $file".to_owned(),
            "translate-c" => "zig translate-c $file".to_owned(),
            "env" => "zig env".to_owned(),
            "help" => "zig help".to_owned(),
            "init" => "zig init".to_owned(),
            "libc" => "zig libc".to_owned(),
            "std" => "zig std".to_owned(),
            "targets" => "zig targets".to_owned(),
            "version" => "zig version".to_owned(),
            "zen" => "zig zen".to_owned(),
            value
                if matches!(
                    value,
                    "ar" | "cc"
                        | "c++"
                        | "dlltool"
                        | "fetch"
                        | "lib"
                        | "objcopy"
                        | "objdump"
                        | "ranlib"
                        | "rc"
                        | "reduce"
                ) =>
            {
                format!("zig {value} $zignite_args")
            }
            _ => generic(),
        },
        Tool::Go => match name {
            "build" => "go build".to_owned(),
            "clean" => "go clean".to_owned(),
            "doc" => "go doc".to_owned(),
            "env" => "go env".to_owned(),
            "fix" => "go fix ./...".to_owned(),
            "fmt" => "go fmt ./...".to_owned(),
            "generate" => "go generate ./...".to_owned(),
            "get" => "go get ./...".to_owned(),
            "install" => "go install ./...".to_owned(),
            "list" => "go list ./...".to_owned(),
            "mod" => "go mod tidy".to_owned(),
            "run" => "go run .".to_owned(),
            "test" => "go test ./...".to_owned(),
            "vet" => "go vet ./...".to_owned(),
            "version" => "go version".to_owned(),
            "work" => "go work sync".to_owned(),
            _ => generic(),
        },
        Tool::Cargo => match name {
            "bench" => "cargo bench".to_owned(),
            "build" => "cargo build".to_owned(),
            "check" => "cargo check".to_owned(),
            "clean" => "cargo clean".to_owned(),
            "clippy" => "cargo clippy".to_owned(),
            "doc" => "cargo doc --open".to_owned(),
            "fetch" => "cargo fetch".to_owned(),
            "fix" => "cargo fix".to_owned(),
            "generate-lockfile" => "cargo generate-lockfile".to_owned(),
            "init" => "cargo init".to_owned(),
            "locate-project" => "cargo locate-project".to_owned(),
            "login" => "cargo login".to_owned(),
            "logout" => "cargo logout".to_owned(),
            "metadata" => "cargo metadata".to_owned(),
            "package" => "cargo package".to_owned(),
            "publish" => "cargo publish".to_owned(),
            "run" => "cargo run".to_owned(),
            "rustc" => "cargo rustc".to_owned(),
            "rustdoc" => "cargo rustdoc".to_owned(),
            "test" => "cargo test".to_owned(),
            "tree" => "cargo tree".to_owned(),
            "update" => "cargo update".to_owned(),
            "vendor" => "cargo vendor".to_owned(),
            "version" => "cargo version".to_owned(),
            value
                if matches!(
                    value,
                    "add" | "install" | "new" | "owner" | "remove" | "search" | "uninstall"
                ) =>
            {
                format!("cargo {value} $zignite_args")
            }
            _ => generic(),
        },
        Tool::Odin => match name {
            "build" => "odin build .".to_owned(),
            "check" => "odin check .".to_owned(),
            "doc" => "odin doc .".to_owned(),
            "run" => "odin run .".to_owned(),
            "test" => "odin test .".to_owned(),
            "version" => "odin version".to_owned(),
            "query" => "odin query $zignite_args".to_owned(),
            _ => generic(),
        },
        Tool::Dart => match name {
            "analyze" => "dart analyze".to_owned(),
            "devtools" => "dart devtools".to_owned(),
            "info" => "dart info".to_owned(),
            value
                if matches!(
                    value,
                    "build"
                        | "compile"
                        | "create"
                        | "doc"
                        | "fix"
                        | "format"
                        | "pub"
                        | "run"
                        | "test"
                ) =>
            {
                format!("dart {value} $zignite_args")
            }
            _ => generic(),
        },
        Tool::Swift => match name {
            "build" => "swift build".to_owned(),
            "repl" => "swift repl".to_owned(),
            "test" => "swift test".to_owned(),
            value if matches!(value, "package" | "run") => format!("swift {value} $zignite_args"),
            _ => generic(),
        },
    }
}

fn quote_shell_name(value: &str) -> String {
    if value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_./+-".contains(&byte))
    {
        return value.to_owned();
    }
    #[cfg(unix)]
    {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
    #[cfg(windows)]
    {
        format!("\"{}\"", value.replace('"', "^\""))
    }
}
