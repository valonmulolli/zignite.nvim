mod bazel;
mod cargo;
mod cmake;
mod common;
mod core;
mod go;
mod gradle;
mod make;
mod maven;
mod meson;
mod package_json;
mod python;
mod zig;

use std::io::{BufRead, Write};

use crate::error::BackendError;
use crate::protocol::{
    has_marker_prefix, parse_request_id, read_line_limited, write_response, RequestId,
    ResponseFrame, DEFAULT_MAX_LINE,
};

pub use core::{
    find_project_root, walk_upward, Project, ProjectCommand, ProjectError, ProjectKind, ProjectRoot,
};
pub use zig::parse_steps as parse_zig_steps;

pub const PROJECT_REQ_BEGIN: &str = "@@ZPRJ_REQ_BEGIN";
pub const PROJECT_REQ_END: &str = "@@ZPRJ_REQ_END";
pub const PROJECT_RES_BEGIN: &str = "@@ZPRJ_RES_BEGIN";
pub const PROJECT_RES_ERR: &str = "@@ZPRJ_RES_ERR";
pub const PROJECT_RES_END: &str = "@@ZPRJ_RES_END";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectOptions {
    pub kind: ProjectKind,
    pub path: String,
    pub match_path: Option<String>,
}

pub fn parse_options(options: &[String]) -> Result<ProjectOptions, ProjectError> {
    let mut kind = None;
    let mut path = None;
    let mut match_path = None;
    for option in options {
        if let Some(value) = option.strip_prefix("--kind=") {
            kind = Some(ProjectKind::parse(value)?);
        } else if let Some(value) = option.strip_prefix("--path=") {
            path = Some(value.to_owned());
        } else if let Some(value) = option.strip_prefix("--match-path=") {
            match_path = Some(value.to_owned());
        } else if option != "--project-parse" {
            return Err(ProjectError::InvalidOption(option.clone()));
        }
    }
    Ok(ProjectOptions {
        kind: kind.ok_or_else(|| ProjectError::InvalidOption("missing --kind=".to_owned()))?,
        path: path.ok_or_else(|| ProjectError::InvalidOption("missing --path=".to_owned()))?,
        match_path,
    })
}

pub fn run_mode<W: Write>(writer: &mut W, options: &[String]) -> Result<(), BackendError> {
    let options = parse_options(options)?;
    let match_path = options.match_path.as_deref().map(std::path::Path::new);
    let project = parse_project(
        options.kind,
        std::path::Path::new(&options.path),
        match_path,
    )?;
    for line in output_lines(&project)? {
        writeln!(writer, "{line}")?;
    }
    writer.flush()?;
    Ok(())
}

pub fn run_daemon<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
) -> Result<(), BackendError> {
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if has_marker_prefix(&line, PROJECT_REQ_BEGIN) {
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
    let request_id = parse_request_id(begin_line, PROJECT_REQ_BEGIN);
    let id = match parse_header(begin_line) {
        Ok(id) => id,
        Err(error) => {
            if let Some(id) = request_id {
                discard_until_end(reader, id)?;
                write_error(writer, id, error)?;
                return Ok(());
            }
            return Err(crate::protocol::ProtocolError::MalformedHeader.into());
        }
    };
    let end_marker = format!("{PROJECT_REQ_END} {}", id.0);
    let mut body = Vec::new();
    let mut body_bytes = 0usize;
    let mut complete = false;
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            complete = true;
            break;
        }
        if !line.starts_with('\t') {
            continue;
        }
        body_bytes = body_bytes.saturating_add(line.len());
        if body_bytes > 4 * 1024 * 1024 {
            write_error(writer, id, "ProjectRequestTooLarge")?;
            discard_until_end(reader, id)?;
            return Ok(());
        }
        body.push(line[1..].to_owned());
    }
    if !complete {
        write_error(writer, id, "UnexpectedEof")?;
        return Ok(());
    }
    match parse_options(&body)
        .and_then(|options| {
            let match_path = options.match_path.as_deref().map(std::path::Path::new);
            parse_project(
                options.kind,
                std::path::Path::new(&options.path),
                match_path,
            )
        })
        .and_then(|project| output_lines(&project))
    {
        Ok(body) => {
            write_response(
                writer,
                ResponseFrame::success(PROJECT_RES_BEGIN, PROJECT_RES_END, id, &body),
            )?;
        }
        Err(error) => write_error(writer, id, &project_error_code(&error))?,
    }
    Ok(())
}

fn output_lines(project: &Project) -> Result<Vec<String>, ProjectError> {
    let root = project.root.to_string_lossy();
    if has_control_chars(&root)
        || project.module.as_deref().is_some_and(has_control_chars)
        || project
            .primary_selector
            .as_deref()
            .is_some_and(has_control_chars)
    {
        return Err(common::invalid_file(
            &project.root,
            "project output contains a control character",
        ));
    }
    let mut lines = Vec::with_capacity(project.commands.len() + 4);
    lines.push(format!("ROOT\t{root}"));
    lines.push(format!("SYSTEM\t{}", project.kind.name()));
    if let Some(module) = &project.module {
        lines.push(format!("MODULE\t{module}"));
    }
    if let Some(selector) = &project.primary_selector {
        lines.push(format!("PRIMARY_SELECTOR\t{selector}"));
    }
    for command in &project.commands {
        lines.push(format!("COMMAND\t{}\t{}", command.name, command.command));
    }
    Ok(lines)
}

fn has_control_chars(value: &str) -> bool {
    value.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
}

fn parse_header(line: &str) -> Result<RequestId, &'static str> {
    let mut fields = line.split_whitespace();
    if fields.next() != Some(PROJECT_REQ_BEGIN) {
        return Err("InvalidProjectDaemonHeader");
    }
    let id = fields
        .next()
        .and_then(|value| value.parse().ok())
        .map(RequestId)
        .ok_or("InvalidProjectDaemonHeader")?;
    if fields.next().is_some() {
        return Err("InvalidProjectDaemonHeader");
    }
    Ok(id)
}

fn discard_until_end<R: BufRead>(reader: &mut R, id: RequestId) -> Result<(), BackendError> {
    let end_marker = format!("{PROJECT_REQ_END} {}", id.0);
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            break;
        }
    }
    Ok(())
}

fn write_error<W: Write>(writer: &mut W, id: RequestId, error: &str) -> Result<(), BackendError> {
    write_response(
        writer,
        ResponseFrame::failure(
            PROJECT_RES_BEGIN,
            PROJECT_RES_ERR,
            PROJECT_RES_END,
            id,
            error,
        ),
    )?;
    Ok(())
}

fn project_error_code(error: &ProjectError) -> String {
    match error {
        ProjectError::InvalidKind(_) => "InvalidProjectKind".to_owned(),
        ProjectError::InvalidOption(_) => "InvalidProjectOptions".to_owned(),
        ProjectError::MissingTool { .. } => "MissingProjectTool".to_owned(),
        ProjectError::CommandFailed { .. } => "ProjectCommandFailed".to_owned(),
        ProjectError::NotFound { .. } => "ProjectNotFound".to_owned(),
        ProjectError::UnreadableMarker { .. } => "UnreadableProjectMarker".to_owned(),
        ProjectError::InvalidFile { .. } => "InvalidProjectFile".to_owned(),
        ProjectError::Io { .. } => "ProjectIoError".to_owned(),
    }
}

pub fn parse_project(
    kind: ProjectKind,
    path: &std::path::Path,
    match_path: Option<&std::path::Path>,
) -> Result<Project, ProjectError> {
    let root = core::require_project_root(path, kind)?;
    match kind {
        ProjectKind::Make => make::parse(root, kind),
        ProjectKind::PackageJson => package_json::parse(root, kind),
        ProjectKind::Cargo => cargo::parse(root, kind, match_path),
        ProjectKind::Go => go::parse(root, kind, match_path),
        ProjectKind::Python => python::parse(root, kind),
        ProjectKind::CMake => cmake::parse(root, kind, match_path),
        ProjectKind::Meson => meson::parse(root, kind, match_path),
        ProjectKind::Bazel => bazel::parse(root, kind, match_path),
        ProjectKind::Maven => maven::parse(root, kind),
        ProjectKind::Gradle => gradle::parse(root, kind),
        ProjectKind::Zig => zig::parse(root, kind),
    }
}
