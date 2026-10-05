use std::fs;
use std::path::{Path, PathBuf};

use zignite::project::{find_project_root, ProjectError, ProjectKind};

struct TempProject {
    path: PathBuf,
}

impl TempProject {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("zignite-project-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("create temporary project");
        Self { path }
    }
}

impl Drop for TempProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[test]
fn finds_the_nearest_marker_and_returns_a_canonical_root() {
    let project = TempProject::new("nearest");
    let nested = project.path.join("src").join("nested");
    fs::create_dir_all(&nested).expect("create nested source directory");
    fs::write(project.path.join("Makefile"), "build:\n\t@true\n").expect("write root marker");

    let result = find_project_root(&nested, ProjectKind::Make)
        .expect("project search succeeds")
        .expect("project exists");

    assert_eq!(
        result.root,
        fs::canonicalize(&project.path).expect("canonical root")
    );
    assert_eq!(result.marker, result.root.join("Makefile"));
}

#[test]
fn missing_markers_return_none_and_invalid_marker_files_are_errors() {
    let project = TempProject::new("missing");
    let source = project.path.join("main.go");
    fs::write(&source, "package main\n").expect("write source");

    assert_eq!(
        find_project_root(&source, ProjectKind::Go).expect("search succeeds"),
        None
    );

    fs::create_dir(project.path.join("go.mod")).expect("create invalid marker path");
    assert!(matches!(
        find_project_root(&source, ProjectKind::Go),
        Err(ProjectError::UnreadableMarker { .. })
    ));
}

#[test]
fn relative_paths_and_duplicate_markers_are_deterministic() {
    let project = TempProject::new("relative");
    let nested = project.path.join("src");
    fs::create_dir_all(&nested).expect("create source directory");
    fs::write(project.path.join("package.json"), "{}\n").expect("write package marker");
    fs::write(project.path.join("package-lock.json"), "{}\n").expect("write lock marker");
    let relative = Path::new(".").join(&nested);

    let result = find_project_root(&relative, ProjectKind::PackageJson)
        .expect("relative search succeeds")
        .expect("package exists");
    assert_eq!(
        result.marker.file_name().and_then(|name| name.to_str()),
        Some("package.json")
    );
}

#[cfg(unix)]
#[test]
fn follows_a_symlinked_source_directory_without_changing_project_root() {
    let project = TempProject::new("symlink");
    let real = project.path.join("real");
    let linked = project.path.join("linked");
    fs::create_dir_all(real.join("src")).expect("create real source directory");
    fs::write(real.join("Cargo.toml"), "[package]\nname = \"demo\"\n").expect("write cargo marker");
    std::os::unix::fs::symlink(&real, &linked).expect("create symlink");

    let result = find_project_root(&linked.join("src"), ProjectKind::Cargo)
        .expect("symlink search succeeds")
        .expect("cargo project exists");
    assert_eq!(result.root, fs::canonicalize(real).expect("real root"));
}

#[cfg(windows)]
#[test]
fn walks_to_a_windows_drive_root() {
    let ancestors = zignite::project::walk_upward(Path::new(r"C:\work\src"));
    assert!(ancestors.iter().any(|path| path == Path::new(r"C:\")));
}
