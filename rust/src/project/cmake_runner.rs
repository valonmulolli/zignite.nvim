use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant, SystemTime};

use crate::error::{BackendError, CliError};
use crate::process::{run_backend_terminal_command, CommandSpec, TimeoutPolicy};

const CODEMODEL_QUERY: &str = ".cmake/api/v1/query/client-zignite/codemodel-v2";

pub fn run_target(
    source_dir: &Path,
    build_dir: &Path,
    target: &str,
    timeout: Option<Duration>,
) -> Result<ExitCode, BackendError> {
    if !source_dir.is_dir() {
        return Err(invalid(format!(
            "CMake source directory does not exist: {}",
            source_dir.display()
        )));
    }
    if target.is_empty() || target.bytes().any(|byte| byte.is_ascii_control()) {
        return Err(invalid("invalid CMake target name"));
    }

    let build_dir = if build_dir.is_absolute() {
        build_dir.to_path_buf()
    } else {
        source_dir.join(build_dir)
    };
    fs::create_dir_all(&build_dir)?;
    let query = build_dir.join(CODEMODEL_QUERY);
    fs::create_dir_all(query.parent().expect("query path has parent"))?;
    fs::write(&query, [])?;

    let started = Instant::now();
    if let Some(code) = run_stage(
        command_spec(
            [
                OsString::from("cmake"),
                OsString::from("-S"),
                source_dir.as_os_str().to_owned(),
                OsString::from("-B"),
                build_dir.as_os_str().to_owned(),
                OsString::from("-DCMAKE_EXPORT_COMPILE_COMMANDS=1"),
            ],
            source_dir,
        ),
        "CMake configure",
        timeout,
        started,
    )? {
        return Ok(code);
    }

    let configuration = multi_config_name(&build_dir)?;
    let mut build_args = vec![
        OsString::from("cmake"),
        OsString::from("--build"),
        build_dir.as_os_str().to_owned(),
        OsString::from("--target"),
        OsString::from(target),
    ];
    if let Some(configuration) = &configuration {
        build_args.push(OsString::from("--config"));
        build_args.push(OsString::from(configuration));
    }
    if let Some(code) = run_stage(
        command_spec(build_args, source_dir),
        "CMake build",
        timeout,
        started,
    )? {
        return Ok(code);
    }

    let executable = target_executable(&build_dir, target, configuration.as_deref())?;
    let spec = CommandSpec {
        argv: vec![executable.as_os_str().to_owned()],
        cwd: Some(source_dir.to_path_buf()),
        env: Vec::new(),
    };
    Ok(run_stage(spec, "program execution", timeout, started)?.unwrap_or(ExitCode::SUCCESS))
}

fn command_spec<I>(argv: I, cwd: &Path) -> CommandSpec
where
    I: IntoIterator<Item = OsString>,
{
    CommandSpec {
        argv: argv.into_iter().collect(),
        cwd: Some(cwd.to_path_buf()),
        env: Vec::new(),
    }
}

fn run_stage(
    spec: CommandSpec,
    stage: &str,
    timeout: Option<Duration>,
    started: Instant,
) -> Result<Option<ExitCode>, BackendError> {
    let remaining = timeout.map(|limit| limit.saturating_sub(started.elapsed()));
    let result = run_backend_terminal_command(
        &spec,
        TimeoutPolicy {
            timeout: remaining,
            grace: Duration::from_millis(100),
        },
        None,
    )?;
    if result.timed_out {
        eprintln!("[Zignite] Timed out during {stage}");
        return Ok(Some(ExitCode::from(124)));
    }
    if !result.status.success() {
        return Ok(Some(ExitCode::from(
            result.status.code().unwrap_or(1).clamp(1, 255) as u8,
        )));
    }
    Ok(None)
}

fn multi_config_name(build_dir: &Path) -> Result<Option<String>, BackendError> {
    let cache = fs::read_to_string(build_dir.join("CMakeCache.txt"))?;
    let Some(configurations) = cache_entry(&cache, "CMAKE_CONFIGURATION_TYPES") else {
        return Ok(None);
    };
    let configurations = configurations
        .split(';')
        .filter(|configuration| !configuration.is_empty())
        .collect::<Vec<_>>();
    if configurations.is_empty() {
        return Ok(None);
    }

    let preferred = cache_entry(&cache, "CMAKE_DEFAULT_BUILD_TYPE");
    let selected = preferred
        .filter(|preferred| {
            configurations
                .iter()
                .any(|configuration| configuration.eq_ignore_ascii_case(preferred))
        })
        .or_else(|| {
            configurations
                .iter()
                .copied()
                .find(|configuration| configuration.eq_ignore_ascii_case("Debug"))
        })
        .unwrap_or(configurations[0]);
    Ok(Some(selected.to_owned()))
}

fn cache_entry<'a>(cache: &'a str, key: &str) -> Option<&'a str> {
    cache.lines().find_map(|line| {
        let (entry, value) = line.split_once('=')?;
        let (name, _) = entry.split_once(':')?;
        (name == key).then_some(value)
    })
}

fn target_executable(
    build_dir: &Path,
    target: &str,
    configuration: Option<&str>,
) -> Result<PathBuf, BackendError> {
    let reply_dir = build_dir.join(".cmake/api/v1/reply");
    let index_path = latest_index(&reply_dir)?;
    let index = read_json(&index_path)?;
    let codemodel_name = index
        .pointer("/reply/client-zignite/codemodel-v2/jsonFile")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| invalid("CMake did not return codemodel v2 data"))?;
    let codemodel_path = reply_dir.join(codemodel_name);
    let codemodel = read_json(&codemodel_path)?;
    let configurations = codemodel
        .get("configurations")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| invalid("CMake codemodel has no configurations"))?;
    let configuration = configuration
        .and_then(|wanted| {
            configurations.iter().find(|candidate| {
                candidate
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|name| name.eq_ignore_ascii_case(wanted))
            })
        })
        .or_else(|| configurations.first())
        .ok_or_else(|| invalid("CMake codemodel has no usable configuration"))?;
    let targets = configuration
        .get("targets")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| invalid("CMake configuration has no targets"))?;
    let target_entry = targets
        .iter()
        .find(|candidate| candidate.get("name").and_then(serde_json::Value::as_str) == Some(target))
        .ok_or_else(|| invalid(format!("CMake target '{target}' was not found")))?;
    let target_json = target_entry
        .get("jsonFile")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| invalid(format!("CMake target '{target}' has no metadata file")))?;
    let target_path = codemodel_path
        .parent()
        .expect("codemodel file has parent")
        .join(target_json);
    let target_data = read_json(&target_path)?;
    if target_data.get("type").and_then(serde_json::Value::as_str) != Some("EXECUTABLE") {
        return Err(invalid(format!(
            "CMake target '{target}' is not executable"
        )));
    }
    let artifact = target_data
        .get("artifacts")
        .and_then(serde_json::Value::as_array)
        .and_then(|artifacts| artifacts.first())
        .and_then(|artifact| artifact.get("path"))
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            invalid(format!(
                "CMake target '{target}' has no executable artifact"
            ))
        })?;
    let artifact = Path::new(artifact);
    let executable = if artifact.is_absolute() {
        artifact.to_path_buf()
    } else {
        build_dir.join(artifact)
    };
    if !executable.is_file() {
        return Err(invalid(format!(
            "CMake reported a missing executable artifact: {}",
            executable.display()
        )));
    }
    Ok(executable)
}

fn latest_index(reply_dir: &Path) -> Result<PathBuf, BackendError> {
    let mut candidates = fs::read_dir(reply_dir)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("index-") && name.ends_with(".json"))
        })
        .map(|path| {
            let modified = fs::metadata(&path)
                .and_then(|metadata| metadata.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            (modified, path)
        })
        .collect::<Vec<_>>();
    candidates.sort_by_key(|(modified, _)| *modified);
    candidates
        .pop()
        .map(|(_, path)| path)
        .ok_or_else(|| invalid("CMake File API did not produce a reply index"))
}

fn read_json(path: &Path) -> Result<serde_json::Value, BackendError> {
    let contents = fs::read_to_string(path)?;
    serde_json::from_str(&contents)
        .map_err(|error| invalid(format!("invalid CMake File API JSON: {error}")))
}

fn invalid(message: impl Into<String>) -> BackendError {
    BackendError::Cli(CliError::InvalidValue(message.into()))
}

#[cfg(test)]
mod tests {
    use super::{cache_entry, multi_config_name, target_executable};
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir() -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "zignite-cmake-file-api-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("create fixture");
        path
    }

    #[test]
    fn chooses_a_supported_multi_config_build_type() {
        let root = temp_dir();
        fs::write(
            root.join("CMakeCache.txt"),
            "CMAKE_CONFIGURATION_TYPES:STRING=Debug;Release\nCMAKE_DEFAULT_BUILD_TYPE:STRING=Release\n",
        )
        .expect("write cache");
        assert_eq!(
            multi_config_name(&root).expect("read cache"),
            Some("Release".into())
        );
        assert_eq!(
            cache_entry(
                "CMAKE_CONFIGURATION_TYPES:STRING=Debug;Release",
                "CMAKE_CONFIGURATION_TYPES"
            ),
            Some("Debug;Release")
        );
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn resolves_custom_multi_config_artifact_path_from_file_api() {
        let root = temp_dir();
        let reply = root.join(".cmake/api/v1/reply");
        fs::create_dir_all(&reply).expect("create reply directory");
        fs::create_dir_all(root.join("out/Release")).expect("create custom output directory");
        let executable = root.join("out/Release/custom-name.exe");
        fs::write(&executable, "fixture").expect("create executable fixture");
        fs::write(
            reply.join("index-test.json"),
            r#"{"reply":{"client-zignite":{"codemodel-v2":{"jsonFile":"codemodel-v2.json"}}}}"#,
        )
        .expect("write reply index");
        fs::write(
            reply.join("codemodel-v2.json"),
            r#"{"configurations":[{"name":"Release","targets":[{"name":"app","jsonFile":"target-app.json"}]}]}"#,
        )
        .expect("write codemodel");
        fs::write(
            reply.join("target-app.json"),
            r#"{"type":"EXECUTABLE","artifacts":[{"path":"out/Release/custom-name.exe"}]}"#,
        )
        .expect("write target metadata");

        assert_eq!(
            target_executable(&root, "app", Some("Release")).expect("resolve artifact"),
            executable
        );
        fs::remove_dir_all(root).expect("remove fixture");
    }

    #[test]
    fn configures_builds_and_runs_custom_cmake_artifact() {
        if std::process::Command::new("cmake")
            .arg("--version")
            .output()
            .is_err()
        {
            return;
        }

        let root = temp_dir();
        fs::create_dir_all(root.join("src")).expect("create source directory");
        fs::write(
            root.join("CMakeLists.txt"),
            "cmake_minimum_required(VERSION 3.16)\nproject(zignite_probe C)\nadd_executable(probe src/main.c)\nset_target_properties(probe PROPERTIES OUTPUT_NAME renamed RUNTIME_OUTPUT_DIRECTORY custom-output)\n",
        )
        .expect("write CMake project");
        fs::write(
            root.join("src/main.c"),
            "#include <stdio.h>\nint main(void) { puts(\"cmake-run-ok\"); return 0; }\n",
        )
        .expect("write executable source");

        let result = super::run_target(&root, &root.join("build"), "probe", None);
        fs::remove_dir_all(&root).expect("remove CMake fixture");
        assert_eq!(
            result.expect("CMake target runs"),
            std::process::ExitCode::SUCCESS
        );
    }
}
