pub mod builtin;
pub mod materialize;
pub mod types;
pub mod zig_classifier;

use std::io::{BufRead, Write};
use std::process::Command;

use crate::config::{ConfigState, RunnerConfig};
use crate::filetype::filetype_from_path;
use crate::paths::{basename, dirname, extension, normalize_path};
use crate::protocol::{
    parse_request_id, read_line_limited, write_response, ResponseFrame, DEFAULT_MAX_LINE,
};
use types::{ResolvedRunner, RunnerSource};

pub const RUN_REQ_BEGIN: &str = "@@ZRUN_REQ_BEGIN";
pub const RUN_REQ_PAYLOAD_BEGIN: &str = "@@ZRUN_REQ_PAYLOAD_BEGIN";
pub const RUN_REQ_PAYLOAD_END: &str = "@@ZRUN_REQ_PAYLOAD_END";
pub const RUN_REQ_END: &str = "@@ZRUN_REQ_END";
pub const RUN_RES_BEGIN: &str = "@@ZRUN_RES_BEGIN";
pub const RUN_RES_ERR: &str = "@@ZRUN_RES_ERR";
pub const RUN_RES_END: &str = "@@ZRUN_RES_END";

pub fn resolve_runner(
    config: &ConfigState,
    path: &str,
    requested_filetype: &str,
    inline_source: Option<&str>,
    context_path: Option<&str>,
) -> Result<ResolvedRunner, String> {
    let filetype = filetype_from_path(requested_filetype, path);
    let execution_path = if path.is_empty() && inline_source.is_some() {
        format!("zignite-inline.{}", extension_for_filetype(&filetype))
    } else {
        normalize_path(path)
    };

    let mut resolved = if let Some(configured) = config.runner_config(&filetype) {
        from_config(configured, &filetype)
    } else if let Some(project) = project_runner(context_path, &filetype) {
        project
    } else {
        builtin::runner(&filetype)
            .map(|runner| ResolvedRunner {
                source: RunnerSource::Builtin,
                filetype: filetype.clone(),
                command: Some(runner.command.to_owned()),
                cleanup_command: runner.cleanup_command.map(str::to_owned),
                name: Some(filetype.clone()),
                ..ResolvedRunner::default()
            })
            .unwrap_or_else(|| ResolvedRunner {
                source: RunnerSource::Filetype,
                filetype: filetype.clone(),
                name: Some(filetype.clone()),
                ..ResolvedRunner::default()
            })
    };

    resolved.execution_path = Some(execution_path.clone());
    resolved.timeout = config.execution_timeout();
    materialize::materialize_runner(&mut resolved, &execution_path)?;
    resolved.missing_tool = missing_tool(&resolved);
    Ok(resolved)
}

pub fn handle_run_frame<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    begin_line: &str,
    config: &ConfigState,
) -> Result<(), crate::error::BackendError> {
    let request_id = parse_request_id(begin_line, RUN_REQ_BEGIN)
        .ok_or(crate::protocol::ProtocolError::MalformedHeader)?;
    let mut args = begin_line
        .split_whitespace()
        .skip(2)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut payload = Vec::new();
    let mut in_payload = false;
    let mut saw_end = false;
    let end_marker = format!("{RUN_REQ_END} {}", request_id.0);
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            saw_end = true;
            break;
        }
        if line == format!("{RUN_REQ_PAYLOAD_BEGIN} {}", request_id.0) {
            if in_payload {
                return write_run_error(writer, request_id, "InvalidRunResolvePayload");
            }
            in_payload = true;
            continue;
        }
        if line == format!("{RUN_REQ_PAYLOAD_END} {}", request_id.0) {
            if !in_payload {
                return write_run_error(writer, request_id, "InvalidRunResolvePayload");
            }
            in_payload = false;
            continue;
        }
        let value = line.strip_prefix('\t').unwrap_or(&line).to_owned();
        if in_payload {
            payload.push(value);
        } else if !value.is_empty() {
            args.push(value);
        }
    }
    if !saw_end || in_payload {
        return write_run_error(writer, request_id, "InvalidRunResolvePayload");
    }

    let path = argument_value(&args, "--path=").unwrap_or_default();
    let filetype = argument_value(&args, "--filetype=").unwrap_or_default();
    if filetype.is_empty() {
        return write_run_error(writer, request_id, "MissingRunResolveFiletype");
    }
    let context_path = argument_value(&args, "--context-path=");
    let inline_source = (!payload.is_empty()).then(|| payload.join("\n"));
    let resolved = match resolve_runner(
        config,
        &path,
        &filetype,
        inline_source.as_deref(),
        context_path.as_deref(),
    ) {
        Ok(resolved) => resolved,
        Err(error) => return write_run_error(writer, request_id, &error),
    };
    let body = serialize_runner(&resolved, config.revision());
    write_response(
        writer,
        ResponseFrame::success(RUN_RES_BEGIN, RUN_RES_END, request_id, &body),
    )?;
    Ok(())
}

fn write_run_error<W: Write>(
    writer: &mut W,
    request_id: crate::protocol::RequestId,
    error: &str,
) -> Result<(), crate::error::BackendError> {
    write_response(
        writer,
        ResponseFrame::failure(RUN_RES_BEGIN, RUN_RES_ERR, RUN_RES_END, request_id, error),
    )?;
    Ok(())
}

pub fn serialize_runner(runner: &ResolvedRunner, revision: u64) -> Vec<String> {
    let ok = (runner.command.is_some() || !runner.argv.is_empty()) && runner.missing_tool.is_none();
    let reason = runner
        .missing_tool
        .as_ref()
        .map(|_| "missing_tool")
        .or_else(|| (!ok).then_some("no_runner"));
    let message = runner
        .missing_tool
        .as_ref()
        .map(|tool| format!("Error: Required executable '{tool}' was not found in PATH."))
        .or_else(|| {
            (!ok).then(|| {
                format!(
                    "Error: No runner configured for filetype: {}",
                    runner.filetype
                )
            })
        });
    let system_argv = if ok {
        backend_command_argv(runner)
    } else {
        Vec::new()
    };
    let json = serde_json::json!({
        "ok": ok,
        "reason": reason,
        "message": message,
        "execution_path": runner.execution_path,
        "command": runner.command,
        "argv": runner.argv,
        "system_argv": system_argv,
        "source": source_name(runner.source),
        "filetype": runner.filetype,
        "cwd": runner.cwd,
        "name": runner.name,
        "missing_tool": runner.missing_tool,
        "config_revision": revision,
    });
    let mut body = vec![format!(
        "RESULT_JSON\t{}",
        serde_json::to_string(&json).unwrap_or_else(|_| "{}".to_owned())
    )];
    body.push(format!("OK\t{}", u8::from(ok)));
    if let Some(reason) = reason {
        body.push(format!("REASON\t{reason}"));
    }
    if let Some(tool) = &runner.missing_tool {
        body.push(format!("MISSING_TOOL\t{tool}"));
        if let Some(message) = &message {
            body.push(format!("MESSAGE\t{message}"));
        }
    } else if let Some(message) = &message {
        body.push(format!("MESSAGE\t{message}"));
    }
    if let Some(command) = &runner.command {
        body.push(format!("COMMAND\t{command}"));
    }
    if let Some(path) = &runner.execution_path {
        body.push(format!("EXECUTION_PATH\t{path}"));
    }
    for arg in &runner.argv {
        body.push(format!("ARGV\t{arg}"));
    }
    body.push(format!("SOURCE\t{}", source_name(runner.source)));
    body.push(format!("FILETYPE\t{}", runner.filetype));
    body.push(format!("CONFIG_REVISION\t{revision}"));
    if let Some(cwd) = &runner.cwd {
        body.push(format!("CWD\t{cwd}"));
    }
    if let Some(name) = &runner.name {
        body.push(format!("NAME\t{name}"));
    }
    body
}

fn source_name(source: RunnerSource) -> &'static str {
    match source {
        RunnerSource::Config => "config",
        RunnerSource::Project => "project",
        RunnerSource::Builtin | RunnerSource::Filetype => "filetype",
    }
}

fn backend_command_argv(runner: &ResolvedRunner) -> Vec<String> {
    let executable = std::env::current_exe()
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| "zignite".to_owned());
    let mut argv = vec![executable];
    if let Some(timeout) = runner.timeout {
        argv.push(format!("--timeout={}", timeout.as_millis()));
    }
    if let Some(cleanup) = &runner.cleanup_command {
        argv.push(format!("--cleanup={cleanup}"));
    }
    if let Some(command) = &runner.command {
        argv.push(command.clone());
    } else {
        argv.push("--argv".to_owned());
        argv.extend(runner.argv.iter().cloned());
    }
    argv
}

fn argument_value(args: &[String], prefix: &str) -> Option<String> {
    args.iter()
        .find_map(|argument| argument.strip_prefix(prefix).map(str::to_owned))
}

fn from_config(config: RunnerConfig, filetype: &str) -> ResolvedRunner {
    match config {
        RunnerConfig::Command(command) => ResolvedRunner {
            source: RunnerSource::Config,
            filetype: filetype.to_owned(),
            command: Some(command),
            name: Some(filetype.to_owned()),
            ..ResolvedRunner::default()
        },
        RunnerConfig::Argv(argv) => ResolvedRunner {
            source: RunnerSource::Config,
            filetype: filetype.to_owned(),
            argv,
            name: Some(filetype.to_owned()),
            ..ResolvedRunner::default()
        },
        RunnerConfig::Object {
            command,
            cleanup_command,
            cwd,
        } => ResolvedRunner {
            source: RunnerSource::Config,
            filetype: filetype.to_owned(),
            command: Some(command.join(" && ")),
            cleanup_command,
            cwd,
            name: Some(filetype.to_owned()),
            ..ResolvedRunner::default()
        },
    }
}

fn project_runner(context_path: Option<&str>, filetype: &str) -> Option<ResolvedRunner> {
    let context = context_path?;
    let mut directory = std::path::Path::new(context);
    if !directory.is_dir() {
        directory = directory.parent()?;
    }
    for root in directory.ancestors() {
        let (manifest, command) = match filetype {
            "zig" if root.join("build.zig").is_file() => ("build.zig", "zig build run"),
            "go" if root.join("go.mod").is_file() => ("go.mod", "go run ."),
            "rust" if root.join("Cargo.toml").is_file() => ("Cargo.toml", "cargo run"),
            _ => continue,
        };
        let _ = manifest;
        return Some(ResolvedRunner {
            source: RunnerSource::Project,
            filetype: filetype.to_owned(),
            command: Some(command.to_owned()),
            cwd: Some(root.to_string_lossy().into_owned()),
            name: Some(format!("{} Project", capitalize(filetype))),
            ..ResolvedRunner::default()
        });
    }
    None
}

fn missing_tool(runner: &ResolvedRunner) -> Option<String> {
    let first = runner.argv.first().map(String::as_str).or_else(|| {
        runner
            .command
            .as_deref()
            .and_then(|command| command.split_whitespace().next())
    })?;
    if first.is_empty() || ["cd", "export", "set"].contains(&first) {
        return None;
    }
    if Command::new(first).arg("--version").output().is_err() {
        Some(first.to_owned())
    } else {
        None
    }
}

fn extension_for_filetype(filetype: &str) -> &str {
    match filetype {
        "c" => "c",
        "cpp" => "cpp",
        "go" => "go",
        "java" => "java",
        "javascript" => "js",
        "kotlin" => "kt",
        "python" => "py",
        "rust" => "rs",
        "typescript" => "ts",
        "zig" => "zig",
        value => value,
    }
}

fn capitalize(value: &str) -> String {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

#[allow(dead_code)]
fn _path_parts(path: &str) -> (&str, &str, &str) {
    (dirname(path), basename(path), extension(path))
}
