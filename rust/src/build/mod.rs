mod action;
mod cache;
mod resolve;
mod types;

use std::fmt;
use std::io::{BufRead, Read, Write};
use std::path::Path;

use crate::config::ConfigState;
use crate::error::BackendError;
use crate::protocol::{
    parse_request_id, read_line_limited, write_response, RequestId, ResponseFrame, DEFAULT_MAX_LINE,
};

pub use action::resolve_action;
pub use resolve::resolve_build;
pub(crate) use resolve::resolve_build_with_state;
pub use types::{ActionKind, ActionPlan, BuildSource, BuildState, CommandEntry, ResolvedBuild};

pub const BUILD_RESOLVE_REQ_BEGIN: &str = "@@ZBR_REQ_BEGIN";
pub const BUILD_RESOLVE_REQ_END: &str = "@@ZBR_REQ_END";
pub const BUILD_RESOLVE_RES_BEGIN: &str = "@@ZBR_RES_BEGIN";
pub const BUILD_RESOLVE_RES_ERR: &str = "@@ZBR_RES_ERR";
pub const BUILD_RESOLVE_RES_END: &str = "@@ZBR_RES_END";
pub const BUILD_ACTION_REQ_BEGIN: &str = "@@ZBA_REQ_BEGIN";
pub const BUILD_ACTION_REQ_END: &str = "@@ZBA_REQ_END";
pub const BUILD_ACTION_RES_BEGIN: &str = "@@ZBA_RES_BEGIN";
pub const BUILD_ACTION_RES_ERR: &str = "@@ZBA_RES_ERR";
pub const BUILD_ACTION_RES_END: &str = "@@ZBA_RES_END";
const MAX_BUILD_BODY_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum BuildError {
    InvalidOptions(String),
    InvalidCommand(String),
    InvalidHeader,
    MissingEndMarker,
    InvalidBodyLine,
    InvalidAction,
    Io(String),
}

impl fmt::Display for BuildError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidOptions(value) => write!(formatter, "invalid build options: {value}"),
            Self::InvalidCommand(value) => write!(formatter, "invalid build command: {value}"),
            Self::InvalidHeader => formatter.write_str("InvalidBuildDaemonHeader"),
            Self::MissingEndMarker => formatter.write_str("UnexpectedEof"),
            Self::InvalidBodyLine => formatter.write_str("InvalidBuildBodyLine"),
            Self::InvalidAction => formatter.write_str("InvalidBuildActionKind"),
            Self::Io(value) => write!(formatter, "build I/O error: {value}"),
        }
    }
}

impl std::error::Error for BuildError {}

impl From<BuildError> for BackendError {
    fn from(error: BuildError) -> Self {
        Self::Build(error)
    }
}

pub fn run_resolve_mode<W: Write>(writer: &mut W, options: &[String]) -> Result<(), BackendError> {
    let options = parse_options(options, false)?;
    let config = config_from_options(&options)?;
    let output = resolve_build(
        &config,
        Path::new(&options.path),
        &options.filetype,
        options.project_root.as_deref(),
    )?;
    write_resolved(writer, &output)?;
    Ok(())
}

pub fn run_action_mode<W: Write>(writer: &mut W, options: &[String]) -> Result<(), BackendError> {
    let options = parse_options(options, true)?;
    let config = config_from_options(&options)?;
    let mut state = BuildState::default();
    let plan = resolve_action(
        &config,
        &mut state,
        Path::new(&options.path),
        &options.filetype,
        options.action.ok_or(BuildError::InvalidAction)?,
        options.command_name.as_deref(),
        options.command_args.as_deref(),
    )?;
    write_action(writer, &plan)?;
    Ok(())
}

pub fn handle_resolve_frame<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    begin_line: &str,
    config: &ConfigState,
    state: &mut BuildState,
) -> Result<(), BackendError> {
    let id = match frame_id(begin_line, BUILD_RESOLVE_REQ_BEGIN) {
        Ok(id) => id,
        Err(error) => {
            if let Some(id) = parse_request_id(begin_line, BUILD_RESOLVE_REQ_BEGIN) {
                discard_until_end(reader, id, BUILD_RESOLVE_REQ_END)?;
                write_response(
                    writer,
                    ResponseFrame::failure(
                        BUILD_RESOLVE_RES_BEGIN,
                        BUILD_RESOLVE_RES_ERR,
                        BUILD_RESOLVE_RES_END,
                        id,
                        "InvalidBuildResolveDaemonHeader",
                    ),
                )?;
                return Ok(());
            }
            return Err(error);
        }
    };
    let body = match read_body(reader, id, BUILD_RESOLVE_REQ_END) {
        Ok(body) => body,
        Err(BackendError::Build(_)) => {
            discard_until_end(reader, id, BUILD_RESOLVE_REQ_END)?;
            write_response(
                writer,
                ResponseFrame::failure(
                    BUILD_RESOLVE_RES_BEGIN,
                    BUILD_RESOLVE_RES_ERR,
                    BUILD_RESOLVE_RES_END,
                    id,
                    "InvalidBuildRequest",
                ),
            )?;
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    let result: Result<ResolvedBuild, String> = parse_options(&body, false)
        .map_err(|error| error.to_string())
        .and_then(|options| {
            resolve_build_with_state(
                config,
                Path::new(&options.path),
                &options.filetype,
                options.project_root.as_deref(),
                state,
            )
            .map_err(|error| error.to_string())
        });
    match result {
        Ok(output) => write_response(
            writer,
            ResponseFrame::success(
                BUILD_RESOLVE_RES_BEGIN,
                BUILD_RESOLVE_RES_END,
                id,
                &serialized_json(&output),
            ),
        )?,
        Err(error) => write_response(
            writer,
            ResponseFrame::failure(
                BUILD_RESOLVE_RES_BEGIN,
                BUILD_RESOLVE_RES_ERR,
                BUILD_RESOLVE_RES_END,
                id,
                &error,
            ),
        )?,
    }
    Ok(())
}

pub fn handle_action_frame<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    begin_line: &str,
    config: &ConfigState,
    state: &mut BuildState,
) -> Result<(), BackendError> {
    let id = match frame_id(begin_line, BUILD_ACTION_REQ_BEGIN) {
        Ok(id) => id,
        Err(error) => {
            if let Some(id) = parse_request_id(begin_line, BUILD_ACTION_REQ_BEGIN) {
                discard_until_end(reader, id, BUILD_ACTION_REQ_END)?;
                write_response(
                    writer,
                    ResponseFrame::failure(
                        BUILD_ACTION_RES_BEGIN,
                        BUILD_ACTION_RES_ERR,
                        BUILD_ACTION_RES_END,
                        id,
                        "InvalidBuildActionDaemonHeader",
                    ),
                )?;
                return Ok(());
            }
            return Err(error);
        }
    };
    let body = match read_body(reader, id, BUILD_ACTION_REQ_END) {
        Ok(body) => body,
        Err(BackendError::Build(_)) => {
            discard_until_end(reader, id, BUILD_ACTION_REQ_END)?;
            write_response(
                writer,
                ResponseFrame::failure(
                    BUILD_ACTION_RES_BEGIN,
                    BUILD_ACTION_RES_ERR,
                    BUILD_ACTION_RES_END,
                    id,
                    "InvalidBuildRequest",
                ),
            )?;
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    let result: Result<ActionPlan, String> = parse_options(&body, true)
        .map_err(|error| error.to_string())
        .and_then(|options| {
            resolve_action(
                config,
                state,
                Path::new(&options.path),
                &options.filetype,
                options
                    .action
                    .ok_or(BuildError::InvalidAction)
                    .map_err(|error| error.to_string())?,
                options.command_name.as_deref(),
                options.command_args.as_deref(),
            )
            .map_err(|error| error.to_string())
        });
    match result {
        Ok(plan) => write_response(
            writer,
            ResponseFrame::success(
                BUILD_ACTION_RES_BEGIN,
                BUILD_ACTION_RES_END,
                id,
                &serialized_json(&plan),
            ),
        )?,
        Err(error) => write_response(
            writer,
            ResponseFrame::failure(
                BUILD_ACTION_RES_BEGIN,
                BUILD_ACTION_RES_ERR,
                BUILD_ACTION_RES_END,
                id,
                &error,
            ),
        )?,
    }
    Ok(())
}

pub(crate) fn parse_action(value: &str) -> Result<ActionKind, BuildError> {
    match value {
        "named" => Ok(ActionKind::Named),
        "live" => Ok(ActionKind::Live),
        "last" => Ok(ActionKind::Last),
        _ => Err(BuildError::InvalidAction),
    }
}

#[derive(Debug, Default)]
struct Options {
    path: String,
    filetype: String,
    project_root: Option<String>,
    command_name: Option<String>,
    command_args: Option<String>,
    action: Option<ActionKind>,
    config_revision: Option<u64>,
    config_stdin: bool,
}

fn parse_options(values: &[String], action: bool) -> Result<Options, BuildError> {
    let mut options = Options::default();
    for value in values {
        if let Some(value) = value.strip_prefix("--path=") {
            options.path = value.to_owned();
        } else if let Some(value) = value.strip_prefix("--filetype=") {
            options.filetype = value.to_owned();
        } else if let Some(value) = value.strip_prefix("--project-root=") {
            options.project_root = Some(value.to_owned());
        } else if let Some(value) = value.strip_prefix("--command-name=") {
            options.command_name = Some(value.to_owned());
        } else if let Some(value) = value.strip_prefix("--command-args=") {
            options.command_args = Some(value.to_owned());
        } else if let Some(value) = value.strip_prefix("--action=") {
            options.action = Some(parse_action(value)?);
        } else if let Some(value) = value.strip_prefix("--config-revision=") {
            options.config_revision = Some(
                value
                    .parse()
                    .map_err(|_| BuildError::InvalidOptions(value.to_owned()))?,
            );
        } else if value == "--config-stdin" {
            options.config_stdin = true;
        } else if value == "--build-resolve" || value == "--build-action" {
            continue;
        } else {
            return Err(BuildError::InvalidOptions(value.clone()));
        }
    }
    if options.path.is_empty() {
        return Err(BuildError::InvalidOptions("missing --path=".to_owned()));
    }
    if options.filetype.is_empty() {
        return Err(BuildError::InvalidOptions("missing --filetype=".to_owned()));
    }
    if action && options.action.is_none() {
        return Err(BuildError::InvalidAction);
    }
    Ok(options)
}

fn config_from_options(options: &Options) -> Result<ConfigState, BackendError> {
    if !options.config_stdin {
        return Ok(ConfigState::default());
    }
    let revision = options
        .config_revision
        .ok_or_else(|| BuildError::InvalidOptions("missing --config-revision=".to_owned()))?;
    let mut json = String::new();
    std::io::stdin().read_to_string(&mut json)?;
    let mut state = ConfigState::default();
    crate::config::apply_config_sync(&mut state, revision, &json)?;
    Ok(state)
}

fn frame_id(line: &str, marker: &str) -> Result<RequestId, BackendError> {
    let id = parse_request_id(line, marker).ok_or(BuildError::InvalidHeader)?;
    if line.split_whitespace().count() != 2 {
        return Err(BuildError::InvalidHeader.into());
    }
    Ok(id)
}

fn read_body<R: BufRead>(
    reader: &mut R,
    id: RequestId,
    end_marker: &str,
) -> Result<Vec<String>, BackendError> {
    let end = format!("{end_marker} {}", id.0);
    let mut body = Vec::new();
    let mut body_bytes = 0usize;
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end {
            return Ok(body);
        }
        if !line.starts_with('\t') {
            return Err(BuildError::InvalidBodyLine.into());
        }
        body_bytes = body_bytes.saturating_add(line.len());
        if body_bytes > MAX_BUILD_BODY_BYTES {
            return Err(BuildError::InvalidBodyLine.into());
        }
        body.push(line[1..].to_owned());
    }
    Err(BuildError::MissingEndMarker.into())
}

fn discard_until_end<R: BufRead>(
    reader: &mut R,
    id: RequestId,
    end_marker: &str,
) -> Result<(), BackendError> {
    let end = format!("{end_marker} {}", id.0);
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end {
            break;
        }
    }
    Ok(())
}

fn serialized_json<T: serde::Serialize>(value: &T) -> Vec<String> {
    let json = serde_json::to_string(value).unwrap_or_else(|_| "{}".to_owned());
    vec![format!("RESULT_JSON\t{json}")]
}

fn write_resolved<W: Write>(writer: &mut W, output: &ResolvedBuild) -> Result<(), BackendError> {
    writeln!(
        writer,
        "RESULT_JSON\t{}",
        serde_json::to_string(output).unwrap_or_else(|_| "{}".to_owned())
    )?;
    Ok(())
}

fn write_action<W: Write>(writer: &mut W, plan: &ActionPlan) -> Result<(), BackendError> {
    writeln!(
        writer,
        "RESULT_JSON\t{}",
        serde_json::to_string(plan).unwrap_or_else(|_| "{}".to_owned())
    )?;
    Ok(())
}
