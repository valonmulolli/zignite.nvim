use std::ffi::OsString;
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::process::ExitCode;
use std::time::Duration;

use zignite::cli::{parse_env_args, Mode};
use zignite::config::{apply_config_sync, ConfigState};
use zignite::daemon::{run_daemon, DaemonState};
use zignite::error::BackendError;
use zignite::process::{run_backend_command, shell_command, CommandSpec, TimeoutPolicy};
use zignite::runtime::{resolve_runner, serialize_runner};

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(error) => {
            eprintln!("Error: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<ExitCode, BackendError> {
    let cli = parse_env_args()?;
    match cli.mode {
        Mode::Daemon => {
            let stdin = io::stdin();
            let stdout = io::stdout();
            let mut reader = BufReader::new(stdin.lock());
            let mut writer = BufWriter::new(stdout.lock());
            run_daemon(&mut reader, &mut writer, &mut DaemonState::default())?;
            Ok(ExitCode::SUCCESS)
        }
        Mode::ConfigSync => run_config_sync_mode(&cli.options),
        Mode::Command => run_command_mode(&cli.argv, &cli.options),
        Mode::Argv => run_argv_mode(&cli.argv, &cli.options),
        Mode::RunResolve => run_run_resolve_mode(&cli.options),
        mode => Err(BackendError::UnsupportedMode(format!("{mode:?}"))),
    }
}

fn run_config_sync_mode(options: &[String]) -> Result<ExitCode, BackendError> {
    let revision = option_value(options, "--revision=")
        .ok_or(zignite::error::CliError::MissingValue("--revision="))?
        .parse::<u64>()
        .map_err(|_| zignite::error::CliError::InvalidValue("--revision=".to_owned()))?;
    let mut json = String::new();
    io::stdin().read_to_string(&mut json)?;
    let mut state = ConfigState::default();
    let warnings = apply_config_sync(&mut state, revision, &json)?;
    for warning in warnings {
        if warning.bytes().any(|byte| byte < 0x20) {
            continue;
        }
        println!("WARN\t{warning}");
    }
    println!("REVISION\t{revision}");
    Ok(ExitCode::SUCCESS)
}

fn run_run_resolve_mode(options: &[String]) -> Result<ExitCode, BackendError> {
    let mut state = ConfigState::default();
    if option_value(options, "--config-stdin=").is_some()
        || options.iter().any(|value| value == "--config-stdin")
    {
        let revision = option_value(options, "--config-revision=")
            .ok_or(zignite::error::CliError::MissingValue("--config-revision="))?
            .parse::<u64>()
            .map_err(|_| zignite::error::CliError::InvalidValue("--config-revision=".to_owned()))?;
        let mut json = String::new();
        io::stdin().read_to_string(&mut json)?;
        apply_config_sync(&mut state, revision, &json)?;
    }
    let path = option_value(options, "--path=").unwrap_or_default();
    let filetype = option_value(options, "--filetype=")
        .ok_or(zignite::error::CliError::MissingValue("--filetype="))?;
    let context_path = option_value(options, "--context-path=");
    let resolved = resolve_runner(&state, path, filetype, None, context_path)
        .map_err(zignite::error::CliError::InvalidValue)?;
    for line in serialize_runner(&resolved, state.revision()) {
        println!("{line}");
    }
    Ok(ExitCode::SUCCESS)
}

fn run_argv_mode(argv: &[String], options: &[String]) -> Result<ExitCode, BackendError> {
    let _program = argv
        .first()
        .ok_or(zignite::error::CliError::MissingValue("--argv <program>"))?;
    let spec = CommandSpec {
        argv: argv.iter().map(OsString::from).collect(),
        cwd: None,
        env: Vec::new(),
    };
    let timeout = parse_timeout(options)?;
    let cleanup = option_value(options, "--cleanup=").map(shell_command);
    let policy = TimeoutPolicy {
        timeout,
        grace: Duration::from_millis(100),
    };
    let result = run_backend_command(&spec, policy, None, cleanup.as_ref())?;
    io::stdout().write_all(&result.stdout)?;
    io::stderr().write_all(&result.stderr)?;
    if result.timed_out {
        eprintln!(
            "[Zignite] Process timed out after {}ms",
            timeout.unwrap_or_default().as_millis()
        );
    }

    if result.status.success() {
        Ok(ExitCode::SUCCESS)
    } else {
        Ok(ExitCode::from(
            result.status.code().unwrap_or(1).clamp(1, 255) as u8,
        ))
    }
}

fn run_command_mode(command: &[String], options: &[String]) -> Result<ExitCode, BackendError> {
    let command = command
        .first()
        .ok_or(zignite::error::CliError::MissingValue("<full command>"))?;
    let timeout = parse_timeout(options)?;
    let cleanup = option_value(options, "--cleanup=").map(shell_command);
    let policy = TimeoutPolicy {
        timeout,
        grace: Duration::from_millis(100),
    };
    let result = run_backend_command(&shell_command(command), policy, None, cleanup.as_ref())?;
    io::stdout().write_all(&result.stdout)?;
    io::stderr().write_all(&result.stderr)?;
    if result.timed_out {
        eprintln!(
            "[Zignite] Process timed out after {}ms",
            timeout.unwrap_or_default().as_millis()
        );
    }

    if result.status.success() {
        Ok(ExitCode::SUCCESS)
    } else {
        Ok(ExitCode::from(
            result.status.code().unwrap_or(1).clamp(1, 255) as u8,
        ))
    }
}

fn parse_timeout(options: &[String]) -> Result<Option<Duration>, BackendError> {
    let Some(value) = option_value(options, "--timeout=") else {
        return Ok(None);
    };
    let milliseconds = value
        .parse::<u64>()
        .map_err(|_| zignite::error::CliError::InvalidValue(value.to_owned()))?;
    Ok(Some(Duration::from_millis(milliseconds)))
}

fn option_value<'a>(options: &'a [String], prefix: &str) -> Option<&'a str> {
    options
        .iter()
        .find_map(|option| option.strip_prefix(prefix))
}
