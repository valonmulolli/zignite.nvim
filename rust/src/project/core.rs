use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const MAX_PROJECT_FILE_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProjectKind {
    Make,
    PackageJson,
    Cargo,
    Go,
    Python,
    CMake,
    Meson,
    Bazel,
    Maven,
    Gradle,
    Zig,
}

impl ProjectKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Make => "make",
            Self::PackageJson => "package-json",
            Self::Cargo => "cargo",
            Self::Go => "go",
            Self::Python => "python",
            Self::CMake => "cmake",
            Self::Meson => "meson",
            Self::Bazel => "bazel",
            Self::Maven => "maven",
            Self::Gradle => "gradle",
            Self::Zig => "zig",
        }
    }

    pub fn parse(value: &str) -> Result<Self, ProjectError> {
        match value.to_ascii_lowercase().as_str() {
            "make" => Ok(Self::Make),
            "package-json" | "package_json" | "packagejson" => Ok(Self::PackageJson),
            "cargo" => Ok(Self::Cargo),
            "go" | "go-mod" | "go-work" => Ok(Self::Go),
            "python" | "pyproject" | "python-auto" => Ok(Self::Python),
            "cmake" => Ok(Self::CMake),
            "meson" => Ok(Self::Meson),
            "bazel" | "bazel-workspace" => Ok(Self::Bazel),
            "maven" | "pom" => Ok(Self::Maven),
            "gradle" => Ok(Self::Gradle),
            "zig" | "zig-auto" => Ok(Self::Zig),
            _ => Err(ProjectError::InvalidKind(value.to_owned())),
        }
    }

    pub(crate) fn markers(self) -> &'static [&'static str] {
        match self {
            Self::Make => &["Makefile", "makefile", "GNUmakefile"],
            Self::PackageJson => &["package.json"],
            Self::Cargo => &["Cargo.toml"],
            Self::Go => &["go.work", "go.mod"],
            Self::Python => &[
                "pyproject.toml",
                "uv.lock",
                "environment.yml",
                "environment.yaml",
                "requirements.txt",
            ],
            Self::CMake => &["CMakeLists.txt"],
            Self::Meson => &["meson.build"],
            Self::Bazel => &[
                "MODULE.bazel",
                "WORKSPACE.bazel",
                "WORKSPACE",
                "BUILD.bazel",
                "BUILD",
            ],
            Self::Maven => &["pom.xml"],
            Self::Gradle => &["build.gradle", "build.gradle.kts"],
            Self::Zig => &["build.zig"],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectRoot {
    pub root: PathBuf,
    pub marker: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectCommand {
    pub name: String,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Project {
    pub kind: ProjectKind,
    pub root: PathBuf,
    pub marker: PathBuf,
    pub commands: Vec<ProjectCommand>,
    pub module: Option<String>,
    pub primary_selector: Option<String>,
}

impl Project {
    pub(crate) fn new(root: ProjectRoot, kind: ProjectKind) -> Self {
        Self {
            kind,
            root: root.root,
            marker: root.marker,
            commands: Vec::new(),
            module: None,
            primary_selector: None,
        }
    }
}

#[derive(Debug)]
pub enum ProjectError {
    InvalidKind(String),
    InvalidOption(String),
    MissingTool { tool: String },
    CommandFailed { tool: String },
    NotFound { kind: ProjectKind, start: PathBuf },
    UnreadableMarker { path: PathBuf },
    InvalidFile { path: PathBuf, message: String },
    Io { path: PathBuf, source: io::Error },
}

impl fmt::Display for ProjectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidKind(value) => write!(formatter, "invalid project kind: {value}"),
            Self::InvalidOption(value) => write!(formatter, "invalid project option: {value}"),
            Self::MissingTool { tool } => {
                write!(formatter, "required project tool missing: {tool}")
            }
            Self::CommandFailed { tool } => write!(formatter, "project tool failed: {tool}"),
            Self::NotFound { kind, start } => {
                write!(
                    formatter,
                    "no {} project found from {}",
                    kind.name(),
                    start.display()
                )
            }
            Self::UnreadableMarker { path } => {
                write!(
                    formatter,
                    "project marker is not a regular file: {}",
                    path.display()
                )
            }
            Self::InvalidFile { path, message } => {
                write!(
                    formatter,
                    "invalid project file {}: {message}",
                    path.display()
                )
            }
            Self::Io { path, source } => {
                write!(formatter, "I/O error for {}: {source}", path.display())
            }
        }
    }
}

impl std::error::Error for ProjectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

pub fn walk_upward(start: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut current = if start.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        start.to_path_buf()
    };

    loop {
        result.push(current.clone());
        let Some(parent) = current.parent() else {
            break;
        };
        if parent == current {
            break;
        }
        current = parent.to_path_buf();
    }
    result
}

pub fn find_project_root(
    start: &Path,
    kind: ProjectKind,
) -> Result<Option<ProjectRoot>, ProjectError> {
    let directory = start_directory(start)?;
    let canonical_directory = fs::canonicalize(&directory).map_err(|source| ProjectError::Io {
        path: directory.clone(),
        source,
    })?;

    let candidates = walk_upward(&canonical_directory);
    if kind == ProjectKind::Go {
        for candidate in &candidates {
            let marker = candidate.join("go.work");
            match fs::metadata(&marker) {
                Ok(metadata) if metadata.is_file() => {
                    return Ok(Some(ProjectRoot {
                        root: candidate.clone(),
                        marker,
                    }));
                }
                Ok(_) => return Err(ProjectError::UnreadableMarker { path: marker }),
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(_) => return Err(ProjectError::UnreadableMarker { path: marker }),
            }
        }
    }
    if kind == ProjectKind::Bazel {
        for candidate in &candidates {
            for marker_name in ["MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE"] {
                let marker = candidate.join(marker_name);
                match fs::metadata(&marker) {
                    Ok(metadata) if metadata.is_file() => {
                        return Ok(Some(ProjectRoot {
                            root: candidate.clone(),
                            marker,
                        }));
                    }
                    Ok(_) => return Err(ProjectError::UnreadableMarker { path: marker }),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(_) => return Err(ProjectError::UnreadableMarker { path: marker }),
                }
            }
        }
    }

    for candidate in candidates {
        for marker_name in kind.markers() {
            let marker = candidate.join(marker_name);
            match fs::metadata(&marker) {
                Ok(metadata) if metadata.is_file() => {
                    return Ok(Some(ProjectRoot {
                        root: candidate,
                        marker,
                    }));
                }
                Ok(_) => return Err(ProjectError::UnreadableMarker { path: marker }),
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(_) => return Err(ProjectError::UnreadableMarker { path: marker }),
            }
        }
    }
    Ok(None)
}

pub(crate) fn require_project_root(
    start: &Path,
    kind: ProjectKind,
) -> Result<ProjectRoot, ProjectError> {
    find_project_root(start, kind)?.ok_or_else(|| ProjectError::NotFound {
        kind,
        start: start.to_path_buf(),
    })
}

pub(crate) fn read_marker(root: &ProjectRoot) -> Result<String, ProjectError> {
    let metadata = fs::metadata(&root.marker).map_err(|source| ProjectError::Io {
        path: root.marker.clone(),
        source,
    })?;
    if metadata.len() > MAX_PROJECT_FILE_BYTES {
        return Err(ProjectError::InvalidFile {
            path: root.marker.clone(),
            message: "file exceeds the project parser size limit".to_owned(),
        });
    }
    let bytes = fs::read(&root.marker).map_err(|source| ProjectError::Io {
        path: root.marker.clone(),
        source,
    })?;
    String::from_utf8(bytes).map_err(|_| ProjectError::InvalidFile {
        path: root.marker.clone(),
        message: "file is not valid UTF-8".to_owned(),
    })
}

fn start_directory(start: &Path) -> Result<PathBuf, ProjectError> {
    match fs::metadata(start) {
        Ok(metadata) if metadata.is_dir() => Ok(start.to_path_buf()),
        Ok(_) => Ok(start
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(start
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf()),
        Err(source) => Err(ProjectError::Io {
            path: start.to_path_buf(),
            source,
        }),
    }
}
