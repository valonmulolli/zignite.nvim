use std::io::BufRead;
use std::io::Write;

use crate::build::{
    handle_action_frame, handle_resolve_frame, BuildState, BUILD_ACTION_REQ_BEGIN,
    BUILD_RESOLVE_REQ_BEGIN,
};
use crate::config::{handle_config_frame, ConfigState, CONFIG_REQ_BEGIN};
use crate::detect::{handle_frame as handle_detect_frame, DETECT_REQ_BEGIN};
use crate::error::BackendError;
use crate::project::{handle_frame as handle_project_frame, PROJECT_REQ_BEGIN};
use crate::protocol::{
    has_marker_prefix, parse_request_id, read_line_limited, write_response, RequestId,
    ResponseFrame, DEFAULT_MAX_LINE,
};
use crate::quickfix::{handle_frame as handle_quickfix_frame, QUICKFIX_REQ_BEGIN};
use crate::runtime::{handle_run_frame, RUN_REQ_BEGIN};

pub const HEALTH_REQ_BEGIN: &str = "@@ZHLT_REQ_BEGIN";
pub const HEALTH_RES_BEGIN: &str = "@@ZHLT_RES_BEGIN";
pub const HEALTH_RES_ERR: &str = "@@ZHLT_RES_ERR";
pub const HEALTH_RES_END: &str = "@@ZHLT_RES_END";

#[derive(Debug, Default)]
pub struct DaemonState {
    pub config_revision: Option<u64>,
    pub config: ConfigState,
    pub build: BuildState,
}

pub fn run_daemon<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    state: &mut DaemonState,
) -> Result<(), BackendError> {
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if has_marker_prefix(&line, CONFIG_REQ_BEGIN) {
            handle_config_frame(reader, writer, &line, &mut state.config)?;
            state.config_revision = Some(state.config.revision());
            continue;
        }
        if has_marker_prefix(&line, RUN_REQ_BEGIN) {
            handle_run_frame(reader, writer, &line, &state.config)?;
            continue;
        }
        if has_marker_prefix(&line, QUICKFIX_REQ_BEGIN) {
            handle_quickfix_frame(reader, writer, &line)?;
            continue;
        }
        if has_marker_prefix(&line, DETECT_REQ_BEGIN) {
            handle_detect_frame(reader, writer, &line)?;
            continue;
        }
        if has_marker_prefix(&line, PROJECT_REQ_BEGIN) {
            handle_project_frame(reader, writer, &line)?;
            continue;
        }
        if has_marker_prefix(&line, BUILD_RESOLVE_REQ_BEGIN) {
            handle_resolve_frame(reader, writer, &line, &state.config, &mut state.build)?;
            continue;
        }
        if has_marker_prefix(&line, BUILD_ACTION_REQ_BEGIN) {
            handle_action_frame(reader, writer, &line, &state.config, &mut state.build)?;
            continue;
        }
        if let Some(id) = parse_request_id(&line, HEALTH_REQ_BEGIN) {
            write_response(
                writer,
                ResponseFrame::success(HEALTH_RES_BEGIN, HEALTH_RES_END, id, &[]),
            )?;
            continue;
        }

        if let Some(id) = recognized_request_id(&line) {
            let (begin, error_marker, end) = response_markers(&line);
            write_response(
                writer,
                ResponseFrame::failure(begin, error_marker, end, id, "UnsupportedMode"),
            )?;
            continue;
        }

        if line.trim().is_empty() {
            continue;
        }
        return Err(crate::protocol::ProtocolError::MalformedHeader.into());
    }
    Ok(())
}

fn recognized_request_id(line: &str) -> Option<RequestId> {
    [
        "@@ZCFG_REQ_BEGIN",
        "@@ZDET_REQ_BEGIN",
        "@@ZPRJ_REQ_BEGIN",
        "@@ZBR_REQ_BEGIN",
        "@@ZBA_REQ_BEGIN",
        "@@ZRUN_REQ_BEGIN",
        "@@ZQF_BEGIN",
    ]
    .iter()
    .find_map(|marker| parse_request_id(line, marker))
}

fn response_markers(line: &str) -> (&'static str, &'static str, &'static str) {
    if has_marker_prefix(line, "@@ZCFG_REQ_BEGIN") {
        return ("@@ZCFG_RES_BEGIN", "@@ZCFG_RES_ERR", "@@ZCFG_RES_END");
    }
    if has_marker_prefix(line, "@@ZDET_REQ_BEGIN") {
        return ("@@ZDET_RES_BEGIN", "@@ZDET_RES_ERR", "@@ZDET_RES_END");
    }
    if has_marker_prefix(line, "@@ZPRJ_REQ_BEGIN") {
        return ("@@ZPRJ_RES_BEGIN", "@@ZPRJ_RES_ERR", "@@ZPRJ_RES_END");
    }
    if has_marker_prefix(line, "@@ZBR_REQ_BEGIN") {
        return ("@@ZBR_RES_BEGIN", "@@ZBR_RES_ERR", "@@ZBR_RES_END");
    }
    if has_marker_prefix(line, "@@ZBA_REQ_BEGIN") {
        return ("@@ZBA_RES_BEGIN", "@@ZBA_RES_ERR", "@@ZBA_RES_END");
    }
    if has_marker_prefix(line, "@@ZRUN_REQ_BEGIN") {
        return ("@@ZRUN_RES_BEGIN", "@@ZRUN_RES_ERR", "@@ZRUN_RES_END");
    }
    ("@@ZQF_RES_BEGIN", "@@ZQF_RES_ERR", "@@ZQF_RES_END")
}
