use std::fmt;
use std::io::{BufRead, Write};
use std::path::Path;
use std::time::Duration;

use serde_json::{Map, Value};

use crate::error::BackendError;
use crate::protocol::{
    parse_request_id, read_line_limited, write_response, ProtocolError, RequestId, ResponseFrame,
    DEFAULT_MAX_LINE,
};

pub const CONFIG_REQ_BEGIN: &str = "@@ZCFG_REQ_BEGIN";
pub const CONFIG_REQ_END: &str = "@@ZCFG_REQ_END";
pub const CONFIG_RES_BEGIN: &str = "@@ZCFG_RES_BEGIN";
pub const CONFIG_RES_ERR: &str = "@@ZCFG_RES_ERR";
pub const CONFIG_RES_END: &str = "@@ZCFG_RES_END";
const MAX_CONFIG_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    InvalidJson,
    InvalidRoot,
    InvalidRevision,
    StaleRevision { current: u64, incoming: u64 },
    InvalidHeader,
    MissingEndMarker,
    InvalidBodyLine,
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidJson => formatter.write_str("InvalidConfigJson"),
            Self::InvalidRoot => formatter.write_str("InvalidConfigRoot"),
            Self::InvalidRevision => formatter.write_str("InvalidConfigRevision"),
            Self::StaleRevision { .. } => formatter.write_str("StaleConfigRevision"),
            Self::InvalidHeader => formatter.write_str("InvalidConfigDaemonHeader"),
            Self::MissingEndMarker => formatter.write_str("MissingConfigRequestEnd"),
            Self::InvalidBodyLine => formatter.write_str("InvalidConfigBodyLine"),
        }
    }
}

impl std::error::Error for ConfigError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunnerConfig {
    Command(String),
    Argv(Vec<String>),
    Object {
        command: Vec<String>,
        cleanup_command: Option<String>,
        cwd: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildCommand {
    pub name: String,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectConfig {
    pub name: Option<String>,
    pub command: String,
    pub cleanup_command: Option<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Default)]
pub struct ConfigState {
    revision: u64,
    value: Option<Value>,
}

impl ConfigState {
    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn execution_timeout(&self) -> Option<Duration> {
        let value = self.root()?.get("timeout")?;
        positive_duration(value)
    }

    pub fn detect_enabled(&self, key: &str) -> Option<bool> {
        self.root()?.get("detect")?.get(key)?.as_bool()
    }

    pub fn runner_config(&self, filetype: &str) -> Option<RunnerConfig> {
        parse_runner(self.root()?.get("runners")?.get(filetype)?)
    }

    pub fn build_commands(&self, filetype: &str) -> Vec<BuildCommand> {
        let Some(commands) = self
            .root()
            .and_then(|root| root.get("build_commands"))
            .and_then(Value::as_object)
            .and_then(|all| all.get(filetype))
            .and_then(Value::as_object)
        else {
            return Vec::new();
        };

        commands
            .iter()
            .filter_map(|(name, value)| {
                let command = value.as_str()?;
                if name.is_empty() || invalid_payload(name) || invalid_payload(command) {
                    return None;
                }
                Some(BuildCommand {
                    name: name.clone(),
                    command: command.to_owned(),
                })
            })
            .collect()
    }

    pub fn project_override(&self, path: &Path) -> Option<ProjectConfig> {
        let projects = self.root()?.get("project")?.as_object()?;
        let path = path.to_string_lossy();

        projects
            .iter()
            .filter_map(|(pattern, value)| {
                let root = matched_project_root(pattern, &path)?;
                let object = value.as_object()?;
                let command = object.get("command")?.as_str()?;
                if command.is_empty() || invalid_payload(command) {
                    return None;
                }
                let name = object
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| !name.is_empty() && !invalid_payload(name))
                    .map(str::to_owned);
                let cleanup_command = object
                    .get("cleanup_command")
                    .and_then(Value::as_str)
                    .filter(|command| !invalid_payload(command))
                    .map(str::to_owned);
                let cwd = object
                    .get("cwd")
                    .and_then(Value::as_str)
                    .filter(|cwd| !cwd.is_empty() && !invalid_payload(cwd))
                    .map(str::to_owned)
                    .or_else(|| (!root.is_empty()).then_some(root.clone()));
                Some((
                    root.len(),
                    ProjectConfig {
                        name,
                        command: command.to_owned(),
                        cleanup_command,
                        cwd,
                    },
                ))
            })
            .max_by_key(|(specificity, _)| *specificity)
            .map(|(_, project)| project)
    }

    fn root(&self) -> Option<&Map<String, Value>> {
        self.value.as_ref()?.as_object()
    }
}

fn matched_project_root(pattern: &str, path: &str) -> Option<String> {
    let pattern = pattern.strip_prefix('^').unwrap_or(pattern);
    let pattern = pattern.strip_suffix('$').unwrap_or(pattern);
    let prefix = pattern.strip_suffix(".*");
    let normalized_path = normalize_project_path(path);
    let matched = match prefix {
        Some(prefix) => {
            let root = trim_project_separator(&normalize_project_path(prefix));
            normalized_path == root
                || if root.ends_with('/') {
                    normalized_path.starts_with(&root)
                } else {
                    normalized_path
                        .strip_prefix(&root)
                        .is_some_and(|suffix| suffix.starts_with('/'))
                }
        }
        None => normalized_path == normalize_project_path(pattern),
    };
    if !matched {
        return None;
    }
    let root = trim_project_separator(&normalize_project_path(prefix.unwrap_or(pattern)));
    Some(root)
}

fn normalize_project_path(path: &str) -> String {
    #[cfg(windows)]
    {
        path.replace('\\', "/").to_lowercase()
    }
    #[cfg(not(windows))]
    {
        path.to_owned()
    }
}

fn trim_project_separator(path: &str) -> String {
    let is_root =
        path == "/" || (path.len() == 3 && path.as_bytes()[1] == b':' && path.ends_with('/'));
    if is_root {
        path.to_owned()
    } else {
        path.trim_end_matches('/').to_owned()
    }
}

pub fn validate_config(json: &str) -> Result<Vec<String>, ConfigError> {
    let value = parse_root(json)?;
    let mut warnings = Vec::new();
    validate_root(&value, &mut warnings);
    Ok(warnings)
}

pub fn apply_config_sync(
    state: &mut ConfigState,
    revision: u64,
    json: &str,
) -> Result<Vec<String>, ConfigError> {
    if revision == 0 {
        return Err(ConfigError::InvalidRevision);
    }
    if revision < state.revision {
        return Err(ConfigError::StaleRevision {
            current: state.revision,
            incoming: revision,
        });
    }
    let value = parse_root(json)?;
    let mut warnings = Vec::new();
    validate_root(&value, &mut warnings);
    state.revision = revision;
    state.value = Some(value);
    Ok(warnings)
}

pub fn handle_config_frame<R: BufRead, W: Write>(
    reader: &mut R,
    writer: &mut W,
    begin_line: &str,
    state: &mut ConfigState,
) -> Result<(), BackendError> {
    let (request_id, revision) = match parse_header(begin_line) {
        Ok(header) => header,
        Err(error) => {
            if let Some(request_id) = parse_request_id(begin_line, CONFIG_REQ_BEGIN) {
                discard_until_end(reader, request_id)?;
                write_response(
                    writer,
                    ResponseFrame::failure(
                        CONFIG_RES_BEGIN,
                        CONFIG_RES_ERR,
                        CONFIG_RES_END,
                        request_id,
                        error.to_string().as_str(),
                    ),
                )?;
                return Ok(());
            }
            return Err(error.into());
        }
    };

    let json = collect_body(reader, request_id)?;
    let warnings = match apply_config_sync(state, revision, &json) {
        Ok(warnings) => warnings,
        Err(error) => {
            write_response(
                writer,
                ResponseFrame::failure(
                    CONFIG_RES_BEGIN,
                    CONFIG_RES_ERR,
                    CONFIG_RES_END,
                    request_id,
                    error.to_string().as_str(),
                ),
            )?;
            return Ok(());
        }
    };
    let mut body = warnings
        .into_iter()
        .filter(|warning| !invalid_payload(warning))
        .map(|warning| format!("WARN\t{warning}"))
        .collect::<Vec<_>>();
    body.push(format!("REVISION\t{revision}"));
    write_response(
        writer,
        ResponseFrame::success(CONFIG_RES_BEGIN, CONFIG_RES_END, request_id, &body),
    )?;
    Ok(())
}

fn parse_header(line: &str) -> Result<(RequestId, u64), ConfigError> {
    let mut fields = line.split_whitespace();
    if fields.next() != Some(CONFIG_REQ_BEGIN) {
        return Err(ConfigError::InvalidHeader);
    }
    let request_id = fields
        .next()
        .and_then(|field| field.parse().ok())
        .map(RequestId)
        .ok_or(ConfigError::InvalidHeader)?;
    let revision = fields
        .next()
        .and_then(|field| field.parse().ok())
        .ok_or(ConfigError::InvalidHeader)?;
    if fields.next().is_some() {
        return Err(ConfigError::InvalidHeader);
    }
    Ok((request_id, revision))
}

fn collect_body<R: BufRead>(reader: &mut R, request_id: RequestId) -> Result<String, BackendError> {
    let end_marker = format!("{CONFIG_REQ_END} {}", request_id.0);
    let mut body = String::new();
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            return Ok(body);
        }
        if !line.starts_with('\t') {
            return Err(ConfigError::InvalidBodyLine.into());
        }
        let value = &line[1..];
        if body.len().saturating_add(value.len()).saturating_add(1) > MAX_CONFIG_BYTES {
            return Err(ProtocolError::LineTooLong {
                limit: MAX_CONFIG_BYTES,
            }
            .into());
        }
        if !body.is_empty() {
            body.push('\n');
        }
        body.push_str(value);
    }
    Err(ConfigError::MissingEndMarker.into())
}

fn discard_until_end<R: BufRead>(
    reader: &mut R,
    request_id: RequestId,
) -> Result<(), BackendError> {
    let end_marker = format!("{CONFIG_REQ_END} {}", request_id.0);
    while let Some(line) = read_line_limited(reader, DEFAULT_MAX_LINE)? {
        if line == end_marker {
            return Ok(());
        }
    }
    Ok(())
}

fn parse_root(json: &str) -> Result<Value, ConfigError> {
    let value: Value = serde_json::from_str(json).map_err(|_| ConfigError::InvalidJson)?;
    if !value.is_object() {
        return Err(ConfigError::InvalidRoot);
    }
    Ok(value)
}

fn parse_runner(value: &Value) -> Option<RunnerConfig> {
    match value {
        Value::String(command) if !command.is_empty() && !invalid_payload(command) => {
            Some(RunnerConfig::Command(command.clone()))
        }
        Value::Array(values) => parse_string_array(values).map(RunnerConfig::Argv),
        Value::Object(object) => {
            let command = parse_command_value(object.get("cmd")?)?;
            let cleanup_command = optional_safe_string(object.get("cleanup_command"));
            let cwd = optional_safe_string(object.get("cwd"));
            Some(RunnerConfig::Object {
                command,
                cleanup_command,
                cwd,
            })
        }
        _ => None,
    }
}

fn parse_command_value(value: &Value) -> Option<Vec<String>> {
    match value {
        Value::String(value) if !value.is_empty() && !invalid_payload(value) => {
            Some(vec![value.clone()])
        }
        Value::Array(values) => parse_string_array(values),
        _ => None,
    }
}

fn parse_string_array(values: &[Value]) -> Option<Vec<String>> {
    let values = values
        .iter()
        .map(|value| value.as_str())
        .collect::<Option<Vec<_>>>()?;
    if values.is_empty()
        || values
            .iter()
            .any(|value| value.is_empty() || invalid_payload(value))
    {
        return None;
    }
    Some(values.into_iter().map(str::to_owned).collect())
}

fn optional_safe_string(value: Option<&Value>) -> Option<String> {
    let value = value?.as_str()?;
    if value.is_empty() || invalid_payload(value) {
        return None;
    }
    Some(value.to_owned())
}

fn positive_duration(value: &Value) -> Option<Duration> {
    match value {
        Value::Number(number) => {
            if let Some(value) = number.as_u64() {
                return (value > 0).then(|| Duration::from_millis(value));
            }
            let value = number.as_f64()?;
            if value.is_finite() && value > 0.0 && value.fract() == 0.0 {
                return Some(Duration::from_millis(value as u64));
            }
            None
        }
        _ => None,
    }
}

fn validate_root(value: &Value, warnings: &mut Vec<String>) {
    let Some(root) = value.as_object() else {
        return;
    };
    if let Some(runners) = root.get("runners") {
        match runners.as_object() {
            Some(runners) => {
                for (filetype, runner) in runners {
                    validate_runner(filetype, runner, warnings);
                }
            }
            None => warnings.push(format!(
                "Invalid config runners: expected object, got {}",
                value_type(runners)
            )),
        }
    }
    if let Some(build_commands) = root.get("build_commands") {
        match build_commands.as_object() {
            Some(build_commands) => validate_build_commands(build_commands, warnings),
            None => warnings.push(format!(
                "Invalid config build_commands: expected object, got {}",
                value_type(build_commands)
            )),
        }
    }
    if let Some(detect) = root.get("detect") {
        match detect.as_object() {
            Some(detect) => {
                for (key, value) in detect {
                    if !value.is_boolean() {
                        warnings.push(format!(
                            "Invalid config detect.{key}: expected boolean, got {}",
                            value_type(value)
                        ));
                    }
                }
            }
            None => warnings.push(format!(
                "Invalid config detect: expected object, got {}",
                value_type(detect)
            )),
        }
    }
    if let Some(project) = root.get("project") {
        match project.as_object() {
            Some(project) => validate_projects(project, warnings),
            None => warnings.push(format!(
                "Invalid config project: expected object, got {}",
                value_type(project)
            )),
        }
    }
    if let Some(timeout) = root.get("timeout") {
        if !timeout.is_null() && positive_duration(timeout).is_none() {
            warnings.push(format!(
                "Invalid config timeout: expected positive number or null, got {}",
                value_type(timeout)
            ));
        }
    }
}

fn validate_runner(filetype: &str, runner: &Value, warnings: &mut Vec<String>) {
    match runner {
        Value::String(command) => {
            if invalid_payload(command) {
                warnings.push(format!(
                    "Invalid config runners.{filetype}: contains control characters or protocol markers"
                ));
            }
        }
        Value::Array(values) => validate_string_array(
            values,
            &format!("Invalid config runners.{filetype}"),
            warnings,
        ),
        Value::Object(object) => {
            let Some(command) = object.get("cmd") else {
                warnings.push(format!(
                    "Invalid config runners.{filetype}: missing cmd field"
                ));
                return;
            };
            match command {
                Value::String(command) if !invalid_payload(command) => {}
                Value::String(_) => warnings.push(format!(
                    "Invalid config runners.{filetype}.cmd: contains control characters or protocol markers"
                )),
                Value::Array(values) => validate_string_array(
                    values,
                    &format!("Invalid config runners.{filetype}.cmd"),
                    warnings,
                ),
                value => warnings.push(format!(
                    "Invalid config runners.{filetype}.cmd: expected string or string[], got {}",
                    value_type(value)
                )),
            }
            validate_optional_string(object, "cleanup_command", filetype, warnings);
            validate_optional_string(object, "cwd", filetype, warnings);
        }
        value => warnings.push(format!(
            "Invalid config runners.{filetype}: expected string, string[], or object, got {}",
            value_type(value)
        )),
    }
}

fn validate_string_array(values: &[Value], prefix: &str, warnings: &mut Vec<String>) {
    for (index, value) in values.iter().enumerate() {
        if let Some(value) = value.as_str() {
            if invalid_payload(value) {
                warnings.push(format!(
                    "{prefix}[{index}]: contains control characters or protocol markers"
                ));
            }
        } else {
            warnings.push(format!(
                "{prefix}[{index}]: expected string, got {}",
                value_type(value)
            ));
        }
    }
}

fn validate_optional_string(
    object: &Map<String, Value>,
    field: &str,
    filetype: &str,
    warnings: &mut Vec<String>,
) {
    let Some(value) = object.get(field) else {
        return;
    };
    match value.as_str() {
        Some(value) if !invalid_payload(value) => {}
        Some(_) => warnings.push(format!(
            "Invalid config runners.{filetype}.{field}: contains control characters or protocol markers"
        )),
        None => warnings.push(format!(
            "Invalid config runners.{filetype}.{field}: expected string, got {}",
            value_type(value)
        )),
    }
}

fn validate_build_commands(commands: &Map<String, Value>, warnings: &mut Vec<String>) {
    for (filetype, commands) in commands {
        let Some(commands) = commands.as_object() else {
            warnings.push(format!(
                "Invalid config build_commands.{filetype}: expected object, got {}",
                value_type(commands)
            ));
            continue;
        };
        for (name, command) in commands {
            if invalid_payload(name) {
                warnings.push(format!(
                    "Invalid config build_commands.{filetype}: command name contains control characters or protocol markers"
                ));
            } else if let Some(command) = command.as_str() {
                if invalid_payload(command) {
                    warnings.push(format!(
                        "Invalid config build_commands.{filetype}.{name}: contains control characters or protocol markers"
                    ));
                }
            } else {
                warnings.push(format!(
                    "Invalid config build_commands.{filetype}.{name}: expected string, got {}",
                    value_type(command)
                ));
            }
        }
    }
}

fn validate_projects(projects: &Map<String, Value>, warnings: &mut Vec<String>) {
    for (pattern, project) in projects {
        if invalid_payload(pattern) {
            warnings.push(format!(
                "Invalid config project.{pattern}: pattern contains control characters or protocol markers"
            ));
            continue;
        }
        let Some(project) = project.as_object() else {
            warnings.push(format!(
                "Invalid config project.{pattern}: expected object, got {}",
                value_type(project)
            ));
            continue;
        };
        let Some(command) = project.get("command") else {
            warnings.push(format!(
                "Invalid config project.{pattern}: missing command field"
            ));
            continue;
        };
        match command.as_str() {
            Some(command) if !command.is_empty() && !invalid_payload(command) => {}
            Some(_) => warnings.push(format!(
                "Invalid config project.{pattern}.command: empty or unsafe command"
            )),
            None => warnings.push(format!(
                "Invalid config project.{pattern}.command: expected string, got {}",
                value_type(command)
            )),
        }
        for field in ["name", "cleanup_command", "cwd"] {
            if let Some(value) = project.get(field) {
                match value.as_str() {
                    Some(value) if !invalid_payload(value) => {}
                    Some(_) => warnings.push(format!(
                        "Invalid config project.{pattern}.{field}: contains control characters or protocol markers"
                    )),
                    None => warnings.push(format!(
                        "Invalid config project.{pattern}.{field}: expected string, got {}",
                        value_type(value)
                    )),
                }
            }
        }
    }
}

fn invalid_payload(value: &str) -> bool {
    value.bytes().any(|byte| byte < 0x20) || value.contains("@@Z")
}

fn value_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}
