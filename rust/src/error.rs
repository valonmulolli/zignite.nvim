use std::fmt;

use crate::protocol::ProtocolError;

#[derive(Debug)]
pub enum BackendError {
    Io(std::io::Error),
    Protocol(ProtocolError),
    Cli(CliError),
    UnsupportedMode(String),
}

impl fmt::Display for BackendError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "I/O error: {error}"),
            Self::Protocol(error) => write!(formatter, "protocol error: {error}"),
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
