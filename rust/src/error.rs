use std::fmt;

use crate::protocol::ProtocolError;

#[derive(Debug)]
pub enum BackendError {
    Io(std::io::Error),
    Process(crate::process::ProcessError),
    Detection(crate::detect::DetectionError),
    Project(crate::project::ProjectError),
    Protocol(ProtocolError),
    Config(crate::config::ConfigError),
    Build(crate::build::BuildError),
    Cli(CliError),
    UnsupportedMode(String),
}

impl fmt::Display for BackendError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "I/O error: {error}"),
            Self::Process(error) => write!(formatter, "process error: {error}"),
            Self::Detection(error) => write!(formatter, "detection error: {error}"),
            Self::Project(error) => write!(formatter, "project error: {error}"),
            Self::Protocol(error) => write!(formatter, "protocol error: {error}"),
            Self::Config(error) => write!(formatter, "config error: {error}"),
            Self::Build(error) => write!(formatter, "build error: {error}"),
            Self::Cli(error) => write!(formatter, "{error}"),
            Self::UnsupportedMode(mode) => write!(formatter, "unsupported mode: {mode}"),
        }
    }
}

impl std::error::Error for BackendError {}

impl From<std::io::Error> for BackendError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<ProtocolError> for BackendError {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

impl From<crate::process::ProcessError> for BackendError {
    fn from(error: crate::process::ProcessError) -> Self {
        Self::Process(error)
    }
}

impl From<crate::detect::DetectionError> for BackendError {
    fn from(error: crate::detect::DetectionError) -> Self {
        Self::Detection(error)
    }
}

impl From<crate::project::ProjectError> for BackendError {
    fn from(error: crate::project::ProjectError) -> Self {
        Self::Project(error)
    }
}

impl From<crate::config::ConfigError> for BackendError {
    fn from(error: crate::config::ConfigError) -> Self {
        Self::Config(error)
    }
}

impl From<CliError> for BackendError {
    fn from(error: CliError) -> Self {
        Self::Cli(error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum CliError {
    MissingValue(&'static str),
    InvalidValue(String),
    UnknownArgument(String),
    MissingMode,
    MultipleModes,
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingValue(argument) => write!(formatter, "missing value for {argument}"),
            Self::InvalidValue(value) => write!(formatter, "invalid argument value: {value}"),
            Self::UnknownArgument(argument) => write!(formatter, "unknown argument: {argument}"),
            Self::MissingMode => formatter.write_str("no command mode was provided"),
            Self::MultipleModes => formatter.write_str("multiple command modes were provided"),
        }
    }
}
