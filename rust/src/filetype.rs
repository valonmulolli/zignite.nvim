use std::collections::HashMap;

pub fn filetype_from_path(requested: &str, path: &str) -> String {
    let requested = alias(requested.trim());
    if let Some(filetype) = filename_filetype(path) {
        return filetype.to_owned();
    }
    if let Some(filetype) = extension_filetype(path) {
        return filetype.to_owned();
    }
    requested.to_owned()
}

pub fn alias(value: &str) -> &str {
    match value {
        "c++" | "cxx" | "objcpp" | "cuda" => "cpp",
        "bash" => "sh",
        "javascriptreact" | "jsx" => "javascript",
        "typescriptreact" | "tsx" => "typescript",
        "cmake" | "make" | "meson" => "cpp",
        "groovy" => "java",
        "objc" => "c",
        value => value,
    }
}

pub fn detect_key(filetype: &str) -> &str {
    alias(filetype)
}

fn filename_filetype(path: &str) -> Option<&'static str> {
    match crate::paths::basename(path) {
        "BUILD" | "BUILD.bazel" | "MODULE.bazel" | "WORKSPACE" | "WORKSPACE.bazel" => Some("bzl"),
        "Cargo.toml" => Some("rust"),
        "CMakeLists.txt" | "GNUmakefile" | "Makefile" | "makefile" | "meson.build" => Some("cpp"),
        "build.gradle" | "pom.xml" | "settings.gradle" => Some("java"),
        "build.gradle.kts" | "settings.gradle.kts" => Some("kotlin"),
        "go.mod" | "go.work" => Some("go"),
        "package.json" | "pnpm-lock.yaml" | "yarn.lock" => Some("javascript"),
        "pyproject.toml" | "requirements.txt" | "uv.lock" => Some("python"),
        _ => None,
    }
}

fn extension_filetype(path: &str) -> Option<&'static str> {
    Some(match crate::paths::extension(path) {
        "c" | "h" => "c",
        "cc" | "cpp" | "cu" | "cuh" | "cxx" | "hh" | "hpp" | "hxx" => "cpp",
        "cjs" | "js" | "mjs" => "javascript",
        "cts" | "mts" | "ts" => "typescript",
        "dart" => "dart",
        "ex" | "exs" => "elixir",
        "f" | "f03" | "f08" | "f90" | "f95" | "for" => "fortran",
        "go" => "go",
        "hs" => "haskell",
        "htm" | "html" => "html",
        "java" => "java",
        "jl" => "julia",
        "json" => "json",
        "kt" | "kts" => "kotlin",
        "lua" => "lua",
        "odin" => "odin",
        "perl" | "pl" | "pm" => "perl",
        "php" => "php",
        "py" | "pyw" => "python",
        "r" => "r",
        "rb" => "ruby",
        "rs" => "rust",
        "sh" => "sh",
        "swift" => "swift",
        "tsx" => "typescript",
        "zig" => "zig",
        "zsh" => "zsh",
        _ => return None,
    })
}

pub fn aliases() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("c++", "cpp"),
        ("bash", "sh"),
        ("javascriptreact", "javascript"),
        ("typescriptreact", "typescript"),
    ])
}
