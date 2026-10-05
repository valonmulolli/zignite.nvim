use std::io::{self, BufReader, BufWriter};
use std::process::ExitCode;

use zignite::cli::{parse_env_args, Mode};
use zignite::daemon::{run_daemon, DaemonState};
use zignite::error::BackendError;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Error: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), BackendError> {
    let cli = parse_env_args()?;
    if cli.mode != Mode::Daemon {
        return Err(BackendError::UnsupportedMode(format!("{:?}", cli.mode)));
    }

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = BufWriter::new(stdout.lock());
    run_daemon(&mut reader, &mut writer, &mut DaemonState::default())
}
