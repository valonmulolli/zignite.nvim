use std::env;

use crate::error::CliError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Daemon,
    ConfigSync,
    Quickfix,
    QuickfixDaemon,
    Detect,
    DetectDaemon,
    ProjectParse,
    ProjectParseDaemon,
    BuildResolve,
    BuildAction,
    RunResolve,
    Command,
    Argv,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cli {
    pub mode: Mode,
    pub options: Vec<String>,
    pub argv: Vec<String>,
}

pub fn parse_env_args() -> Result<Cli, CliError> {
    parse_args(env::args().skip(1))
}

pub fn parse_args<I, S>(args: I) -> Result<Cli, CliError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let args = args.into_iter().map(Into::into).collect::<Vec<_>>();
    let mut mode = None;
    let mut options = Vec::new();
    let mut argv = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let argument = &args[index];
        if argument == "--argv" {
            mode = set_mode(mode, Mode::Argv)?;
            argv.extend(args[index + 1..].iter().cloned());
            break;
        }
        if let Some(candidate) = mode_for(argument) {
            mode = set_mode(mode, candidate)?;
            index += 1;
            continue;
        }
        if argument.starts_with("--") {
            options.push(argument.clone());
            index += 1;
            continue;
        }
        mode = set_mode(mode, Mode::Command)?;
        argv.push(argument.clone());
        break;
    }

    let mode = mode.ok_or(CliError::MissingMode)?;
    Ok(Cli {
        mode,
        options,
        argv,
    })
}

fn mode_for(argument: &str) -> Option<Mode> {
    Some(match argument {
        "--daemon" => Mode::Daemon,
        "--config-sync" => Mode::ConfigSync,
        "--quickfix" => Mode::Quickfix,
        "--quickfix-daemon" => Mode::QuickfixDaemon,
        "--detect" => Mode::Detect,
        "--detect-daemon" => Mode::DetectDaemon,
        "--project-parse" => Mode::ProjectParse,
        "--project-parse-daemon" => Mode::ProjectParseDaemon,
        "--build-resolve" => Mode::BuildResolve,
        "--build-action" => Mode::BuildAction,
        "--run-resolve" => Mode::RunResolve,
        _ => return None,
    })
}

fn set_mode(current: Option<Mode>, next: Mode) -> Result<Option<Mode>, CliError> {
    if current.is_some() {
        return Err(CliError::MultipleModes);
    }
    Ok(Some(next))
}

#[cfg(test)]
mod tests {
    use super::{parse_args, Mode};

    #[test]
    fn parses_a_shell_command_after_process_options() {
        let cli = parse_args(["--timeout=50", "printf hello"]).expect("command parses");

        assert_eq!(cli.mode, Mode::Command);
        assert_eq!(cli.options, vec!["--timeout=50"]);
        assert_eq!(cli.argv, vec!["printf hello"]);
    }

    #[test]
    fn argv_mode_keeps_child_flags_out_of_backend_options() {
        let cli = parse_args(["--argv", "printf", "--timeout=child"]).expect("argv parses");

        assert_eq!(cli.mode, Mode::Argv);
        assert!(cli.options.is_empty());
        assert_eq!(cli.argv, vec!["printf", "--timeout=child"]);
    }
}
