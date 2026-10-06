use std::env;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

pub(crate) fn executable_available(program: &str, cwd: Option<&Path>) -> bool {
    let path = env::var_os("PATH");
    let path_ext = env::var_os("PATHEXT");
    executable_available_in(program, cwd, path.as_deref(), path_ext.as_deref())
}

fn executable_available_in(
    program: &str,
    cwd: Option<&Path>,
    search_path: Option<&OsStr>,
    path_ext: Option<&OsStr>,
) -> bool {
    let program_path = Path::new(program);
    if program_path.is_absolute() || program_path.components().count() > 1 {
        let candidate = if program_path.is_relative() {
            cwd.map_or_else(|| program_path.to_path_buf(), |cwd| cwd.join(program_path))
        } else {
            program_path.to_path_buf()
        };
        return executable_file(&candidate);
    }

    let Some(search_path) = search_path else {
        return false;
    };
    env::split_paths(search_path).any(|directory| {
        let directory = if directory.as_os_str().is_empty() {
            cwd.unwrap_or(Path::new(".")).to_path_buf()
        } else if directory.is_relative() {
            cwd.map_or(directory.clone(), |cwd| cwd.join(&directory))
        } else {
            directory
        };
        executable_candidates(program, &directory, path_ext)
            .iter()
            .any(|candidate| executable_file(candidate))
    })
}

fn executable_candidates(
    program: &str,
    directory: &Path,
    path_ext: Option<&OsStr>,
) -> Vec<PathBuf> {
    let candidate = directory.join(program);
    #[cfg(windows)]
    {
        if candidate.extension().is_some() {
            return vec![candidate];
        }
        let extensions = path_ext
            .map(OsStr::to_string_lossy)
            .unwrap_or_else(|| ".COM;.EXE;.BAT;.CMD".into());
        return extensions
            .split(';')
            .filter(|extension| !extension.is_empty())
            .map(|extension| {
                let mut path = candidate.as_os_str().to_os_string();
                path.push(extension);
                PathBuf::from(path)
            })
            .collect();
    }
    #[cfg(not(windows))]
    {
        let _ = path_ext;
        vec![candidate]
    }
}

#[cfg(unix)]
fn executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(windows)]
fn executable_file(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
}

#[cfg(not(any(unix, windows)))]
fn executable_file(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
}

#[cfg(test)]
mod tests {
    use super::executable_available_in;
    use std::ffi::OsStr;
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir() -> std::path::PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("zignite-path-{}-{unique}", std::process::id()));
        fs::create_dir_all(&path).expect("create temporary directory");
        path
    }

    #[test]
    fn searches_path_without_executing_the_program() {
        let dir = temp_dir();
        let program = if cfg!(windows) { "probe.cmd" } else { "probe" };
        let executable = dir.join(program);
        fs::write(&executable, "this file is only checked, never run").expect("write executable");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755))
                .expect("make executable");
        }

        let path = std::env::join_paths([&dir]).expect("join search path");
        let extensions = OsStr::new(".COM;.EXE;.BAT;.CMD");
        assert!(executable_available_in(
            "probe",
            None,
            Some(&path),
            Some(extensions),
        ));
        assert!(!executable_available_in(
            "not-present",
            None,
            Some(&path),
            Some(extensions),
        ));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn checks_relative_paths_against_runner_cwd() {
        let dir = temp_dir();
        let executable = dir.join("local-tool");
        fs::write(&executable, "not executed").expect("write executable");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755))
                .expect("make executable");
        }

        assert!(executable_available_in(
            "./local-tool",
            Some(Path::new(&dir)),
            None,
            None,
        ));
        let _ = fs::remove_dir_all(&dir);
    }
}
