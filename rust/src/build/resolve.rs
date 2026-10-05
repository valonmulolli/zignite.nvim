use std::fs;
use std::path::Path;

use crate::config::ConfigState;
use crate::filetype::{alias, filetype_from_path};
use crate::project::{find_project_root, parse_project, ProjectKind};
use crate::runtime::materialize::substitute_variables_shell;

use super::types::{BuildSource, BuildState, CommandEntry, ResolvedBuild};

pub fn resolve_build(
    config: &ConfigState,
    path: &Path,
    requested_filetype: &str,
    project_root: Option<&str>,
) -> Result<ResolvedBuild, super::BuildError> {
    resolve_build_internal(config, path, requested_filetype, project_root, None)
}

pub(crate) fn resolve_build_with_state(
    config: &ConfigState,
    path: &Path,
    requested_filetype: &str,
    project_root: Option<&str>,
    state: &mut BuildState,
) -> Result<ResolvedBuild, super::BuildError> {
    resolve_build_internal(config, path, requested_filetype, project_root, Some(state))
}

fn resolve_build_internal(
    config: &ConfigState,
    path: &Path,
    requested_filetype: &str,
    project_root: Option<&str>,
    state: Option<&mut BuildState>,
) -> Result<ResolvedBuild, super::BuildError> {
    let requested = alias(requested_filetype.trim());
    let filetype = if !config.build_commands(requested).is_empty() {
        requested.to_owned()
    } else {
        filetype_from_path(requested_filetype, &path.to_string_lossy())
    };
    let mut resolved = ResolvedBuild {
        ok: false,
        reason: None,
        message: None,
        filetype: filetype.clone(),
        root: project_root.map(str::to_owned),
        system: None,
        build_ready: None,
        commands: Vec::new(),
        command_entries: Vec::new(),
        completion_names: Vec::new(),
        preferred_commands: Vec::new(),
        preferred_names: Vec::new(),
        live_preferred_name: None,
        last_command_name: None,
        config_revision: config.revision(),
    };

    add_builtins(&mut resolved.commands, &filetype);
    for (index, kind) in project_kinds(&filetype).iter().enumerate() {
        let Some(found_root) =
            find_project_root(project_root.map(Path::new).unwrap_or(path), *kind)
                .ok()
                .flatten()
        else {
            continue;
        };
        let parse_start = project_root.map(Path::new).unwrap_or(path);
        let Ok(project) = parse_project(*kind, parse_start, Some(path)) else {
            continue;
        };
        if index == 0 || resolved.root.is_none() {
            resolved.root = Some(found_root.root.to_string_lossy().into_owned());
            resolved.system = Some(project.kind.name().to_owned());
            resolved.build_ready =
                add_project_defaults(&mut resolved.commands, *kind, &found_root.root);
        }
        for command in project.commands {
            let name = command.name;
            let command = command.command;
            let entry = CommandEntry::new(name.clone(), command.clone(), BuildSource::Project)
                .with_filetype(&filetype);
            if index == 0 {
                upsert(&mut resolved.commands, entry);
            } else {
                insert_if_absent(&mut resolved.commands, entry);
            }
            if *kind == ProjectKind::PackageJson && name == "dev" {
                insert_if_absent(
                    &mut resolved.commands,
                    CommandEntry::new("live", command, BuildSource::Project)
                        .with_filetype(&filetype),
                );
            }
        }
        if !matches!(filetype.as_str(), "go") {
            break;
        }
    }
    for command in config.build_commands(&filetype) {
        let materialized = substitute_variables_shell(&command.command, &path.to_string_lossy());
        upsert(
            &mut resolved.commands,
            CommandEntry::new(command.name, materialized, BuildSource::Config)
                .with_filetype(&filetype),
        );
    }

    resolved
        .commands
        .retain(|entry| safe_payload(&entry.name) && safe_payload(&entry.command));
    resolved.command_entries = resolved.commands.clone();
    resolved.completion_names = resolved
        .commands
        .iter()
        .map(|entry| entry.name.clone())
        .collect();
    for preferred_name in ["run", "live", "dev", "start", "build", "test", "check"] {
        if let Some(entry) = resolved.command(preferred_name).cloned() {
            resolved.preferred_names.push(entry.name.clone());
            if entry.name == "live" {
                resolved.live_preferred_name = Some(entry.name.clone());
            }
            resolved.preferred_commands.push(entry);
        }
    }
    if resolved.preferred_names.is_empty() {
        resolved.preferred_names = resolved.completion_names.iter().take(1).cloned().collect();
        resolved.preferred_commands = resolved
            .preferred_names
            .iter()
            .filter_map(|name| resolved.command(name).cloned())
            .collect();
    }
    if let Some(state) = state {
        if let Some(name) = state.last(&filetype).map(str::to_owned) {
            if resolved.command(&name).is_some() {
                resolved.last_command_name = Some(name);
            } else {
                state.clear(&filetype);
            }
        }
    }
    resolved.ok = !resolved.commands.is_empty();
    if !resolved.ok {
        resolved.reason = Some("no_commands".to_owned());
        resolved.message = Some(format!(
            "No build commands available for filetype: {filetype}"
        ));
    }
    Ok(resolved)
}

fn project_kinds(filetype: &str) -> &'static [ProjectKind] {
    match filetype {
        "zig" => &[ProjectKind::Zig, ProjectKind::Make, ProjectKind::Cargo],
        "rust" => &[ProjectKind::Cargo, ProjectKind::Make, ProjectKind::Bazel],
        "go" => &[ProjectKind::Make, ProjectKind::Go, ProjectKind::Bazel],
        "javascript" | "typescript" => &[
            ProjectKind::PackageJson,
            ProjectKind::Make,
            ProjectKind::Bazel,
        ],
        "python" => &[ProjectKind::Python, ProjectKind::Make, ProjectKind::Bazel],
        "java" | "kotlin" => &[ProjectKind::Maven, ProjectKind::Gradle, ProjectKind::Make],
        "c" | "cpp" => &[
            ProjectKind::CMake,
            ProjectKind::Meson,
            ProjectKind::Make,
            ProjectKind::Bazel,
        ],
        _ => &[
            ProjectKind::Make,
            ProjectKind::Bazel,
            ProjectKind::PackageJson,
        ],
    }
}

fn add_builtins(commands: &mut Vec<CommandEntry>, filetype: &str) {
    let entries: &[(&str, &str)] = match filetype {
        "zig" => &[
            ("build", "zig build"),
            ("run", "zig build run"),
            ("test", "zig build test"),
            ("check", "zig build check"),
            ("release", "zig build -Doptimize=ReleaseFast"),
            ("release-run", "zig build run -Doptimize=ReleaseFast"),
            ("fetch", "zig fetch $zignite_args"),
        ],
        "rust" => &[
            ("build", "cargo build"),
            ("run", "cargo run"),
            ("test", "cargo test"),
            ("release", "cargo build --release"),
            ("release-run", "cargo run --release"),
            ("check", "cargo check"),
            ("clean", "cargo clean"),
        ],
        "go" => &[
            ("build", "go build"),
            ("run", "go run ."),
            ("test", "go test ./..."),
            ("clean", "go clean"),
            ("mod", "go mod tidy"),
        ],
        "odin" => &[
            ("build", "odin build ."),
            ("run", "odin run ."),
            ("test", "odin test ."),
            ("release", "odin build . -o:speed"),
            ("check", "odin check ."),
        ],
        "python" => &[
            ("run", "python -m main"),
            ("test", "pytest"),
            ("install", "pip install -r requirements.txt"),
        ],
        "javascript" | "typescript" => &[
            ("start", "npm start"),
            ("dev", "npm run dev"),
            ("build", "npm run build"),
            ("test", "npm test"),
            ("install", "npm install"),
        ],
        "c" | "cpp" => &[],
        _ => &[],
    };
    for (name, command) in entries {
        upsert(
            commands,
            CommandEntry::new(*name, *command, BuildSource::Builtin).with_filetype(filetype),
        );
    }
}

fn add_project_defaults(
    commands: &mut Vec<CommandEntry>,
    kind: ProjectKind,
    root: &Path,
) -> Option<bool> {
    match kind {
        ProjectKind::CMake => {
            let (build_dir, ready) = discovered_build_dir(root, "CMakeCache.txt");
            let build_dir = shell_word(&build_dir);
            let build = if ready {
                format!("cmake --build {build_dir}")
            } else {
                format!(
                    "cmake -B {build_dir} -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {build_dir}"
                )
            };
            let clean = if ready {
                format!("cmake --build {build_dir} --target clean")
            } else {
                format!(
                    "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- {build_dir}"
                )
            };
            for (name, command) in [
                ("cmake-config", format!("cmake -B {build_dir} -DCMAKE_EXPORT_COMPILE_COMMANDS=1")),
                ("cmake-build", build.clone()),
                ("build", build),
                ("cmake-clean", clean.clone()),
                ("clean", clean),
                (
                    "cmake-debug",
                    format!("cmake -B {build_dir} -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {build_dir}"),
                ),
                (
                    "debug",
                    format!("cmake -B {build_dir} -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {build_dir}"),
                ),
                (
                    "cmake-release",
                    format!("cmake -B {build_dir} -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {build_dir}"),
                ),
                (
                    "release",
                    format!("cmake -B {build_dir} -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {build_dir}"),
                ),
                ("cmake-test", format!("ctest --test-dir {build_dir}")),
                ("test", format!("ctest --test-dir {build_dir}")),
                ("install", format!("cmake --build {build_dir} --target install")),
            ] {
                insert_if_absent(
                    commands,
                    CommandEntry::new(name, command, BuildSource::Project),
                );
            }
            Some(ready)
        }
        ProjectKind::Meson => {
            let (build_dir, ready) = discovered_build_dir(root, "build.ninja");
            let build_dir = shell_word(&build_dir);
            let build = if ready {
                format!("meson compile -C {build_dir}")
            } else {
                format!("meson setup {build_dir} && meson compile -C {build_dir}")
            };
            let clean = if ready {
                format!("meson compile -C {build_dir} --clean")
            } else {
                format!(
                    "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- {build_dir}"
                )
            };
            for (name, command) in [
                ("meson-setup", format!("meson setup {build_dir}")),
                ("setup", format!("meson setup {build_dir}")),
                ("meson-build", build.clone()),
                ("build", build),
                ("meson-clean", clean.clone()),
                ("clean", clean),
                ("meson-test", format!("meson test -C {build_dir}")),
                ("test", format!("meson test -C {build_dir}")),
                ("install", format!("meson install -C {build_dir}")),
            ] {
                insert_if_absent(
                    commands,
                    CommandEntry::new(name, command, BuildSource::Project),
                );
            }
            Some(ready)
        }
        ProjectKind::Bazel => {
            insert_if_absent(
                commands,
                CommandEntry::new("build", "bazel build //...", BuildSource::Project),
            );
            insert_if_absent(
                commands,
                CommandEntry::new("test", "bazel test //...", BuildSource::Project),
            );
            None
        }
        _ => None,
    }
}

fn discovered_build_dir(root: &Path, marker: &str) -> (String, bool) {
    for candidate in ["build", "build-debug", "build-release"] {
        if root.join(candidate).join(marker).is_file() {
            return (candidate.to_owned(), true);
        }
    }
    let Ok(entries) = fs::read_dir(root) else {
        return ("build".to_owned(), false);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.join(marker).is_file() {
            if let Some(name) = path.file_name().and_then(|name| name.to_str()) {
                return (name.to_owned(), true);
            }
        }
    }
    ("build".to_owned(), false)
}

fn shell_word(value: &str) -> String {
    if value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"._/-:".contains(&byte))
    {
        value.to_owned()
    } else {
        crate::paths::quote_shell_arg(value)
    }
}

pub(crate) fn upsert(commands: &mut Vec<CommandEntry>, entry: CommandEntry) {
    if let Some(existing) = commands.iter_mut().find(|item| item.name == entry.name) {
        *existing = entry;
    } else {
        commands.push(entry);
    }
}

fn insert_if_absent(commands: &mut Vec<CommandEntry>, entry: CommandEntry) {
    if !commands.iter().any(|item| item.name == entry.name) {
        commands.push(entry);
    }
}

pub(crate) fn safe_payload(value: &str) -> bool {
    !value.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
}
