pub struct BuiltinRunner {
    pub command: &'static str,
    pub cleanup_command: Option<&'static str>,
}

#[cfg(unix)]
const C_COMMAND: &str = "gcc -pipe $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt";
#[cfg(unix)]
const CPP_COMMAND: &str = "c++ -pipe $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt";
#[cfg(unix)]
const RUST_COMMAND: &str = "rustc $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt";
#[cfg(unix)]
const FORTRAN_COMMAND: &str =
    "gfortran $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt";
#[cfg(unix)]
const TEMP_BINARY_CLEANUP: &str = "rm -f /tmp/$fileNameWithoutExt";
#[cfg(windows)]
const C_COMMAND: &str =
    "gcc -pipe $file -o \"%TEMP%/zignite-$fileNameWithoutExt.exe\" && \"%TEMP%/zignite-$fileNameWithoutExt.exe\"";
#[cfg(windows)]
const CPP_COMMAND: &str =
    "c++ -pipe $file -o \"%TEMP%/zignite-$fileNameWithoutExt.exe\" && \"%TEMP%/zignite-$fileNameWithoutExt.exe\"";
#[cfg(windows)]
const RUST_COMMAND: &str =
    "rustc $file -o \"%TEMP%/zignite-$fileNameWithoutExt.exe\" && \"%TEMP%/zignite-$fileNameWithoutExt.exe\"";
#[cfg(windows)]
const FORTRAN_COMMAND: &str =
    "gfortran $file -o \"%TEMP%/zignite-$fileNameWithoutExt.exe\" && \"%TEMP%/zignite-$fileNameWithoutExt.exe\"";
#[cfg(windows)]
const TEMP_BINARY_CLEANUP: &str =
    "if exist \"%TEMP%/zignite-$fileNameWithoutExt.exe\" del /Q \"%TEMP%/zignite-$fileNameWithoutExt.exe\"";

#[cfg(unix)]
const PYTHON_COMMAND: &str = "python3 -u $file";
#[cfg(windows)]
const PYTHON_COMMAND: &str = "python -u $file";
#[cfg(unix)]
const SHELL_COMMAND: &str = "bash $file";
#[cfg(windows)]
const SHELL_COMMAND: &str = "sh $file";
#[cfg(target_os = "macos")]
const OPEN_FILE_COMMAND: &str = "open $file";
#[cfg(target_os = "windows")]
const OPEN_FILE_COMMAND: &str = "explorer $file";
#[cfg(all(unix, not(target_os = "macos")))]
const OPEN_FILE_COMMAND: &str = "xdg-open $file";

#[cfg(unix)]
const KOTLIN_COMMAND: &str =
    "kotlinc $file -include-runtime -d /tmp/$fileNameWithoutExt.jar && java -jar /tmp/$fileNameWithoutExt.jar";
#[cfg(unix)]
const KOTLIN_CLEANUP: &str = "rm -f /tmp/$fileNameWithoutExt.jar";
#[cfg(windows)]
const KOTLIN_COMMAND: &str =
    "kotlinc $file -include-runtime -d \"%TEMP%/zignite-$fileNameWithoutExt.jar\" && java -jar \"%TEMP%/zignite-$fileNameWithoutExt.jar\"";
#[cfg(windows)]
const KOTLIN_CLEANUP: &str =
    "if exist \"%TEMP%/zignite-$fileNameWithoutExt.jar\" del /Q \"%TEMP%/zignite-$fileNameWithoutExt.jar\"";

pub fn runner(filetype: &str) -> Option<BuiltinRunner> {
    if let Some(runner) = compiled_runner(filetype) {
        return Some(runner);
    }

    let (command, cleanup_command) = match filetype {
        "dart" => ("dart run $file", None),
        "elixir" => ("elixir $file", None),
        "go" => ("go run $file", None),
        "java" => (
            "javac $file && java -cp $dir $fileNameWithoutExt",
            Some(java_cleanup()),
        ),
        "javascript" => ("node $file", None),
        "julia" => ("julia $file", None),
        "lua" => ("lua $file", None),
        "odin" => ("odin run $file -file", None),
        "perl" => ("perl $file", None),
        "php" => ("php $file", None),
        "python" => (PYTHON_COMMAND, None),
        "r" => ("Rscript $file", None),
        "ruby" => ("ruby $file", None),
        "sh" => (SHELL_COMMAND, None),
        "swift" => ("swift $file", None),
        "typescript" => ("bun $file", None),
        "zig" => ("zig run $file", None),
        "zsh" => ("zsh $file", None),
        "html" => (OPEN_FILE_COMMAND, None),
        _ => return None,
    };
    Some(BuiltinRunner {
        command,
        cleanup_command,
    })
}

fn compiled_runner(filetype: &str) -> Option<BuiltinRunner> {
    let (command, cleanup_command) = match filetype {
        "c" => (C_COMMAND, Some(TEMP_BINARY_CLEANUP)),
        "cpp" => (CPP_COMMAND, Some(TEMP_BINARY_CLEANUP)),
        "fortran" => (FORTRAN_COMMAND, Some(TEMP_BINARY_CLEANUP)),
        "haskell" => (HASKELL_COMMAND, Some(TEMP_BINARY_CLEANUP)),
        "kotlin" => (KOTLIN_COMMAND, Some(KOTLIN_CLEANUP)),
        "rust" => (RUST_COMMAND, Some(TEMP_BINARY_CLEANUP)),
        _ => return None,
    };
    Some(BuiltinRunner {
        command,
        cleanup_command,
    })
}

#[cfg(unix)]
const HASKELL_COMMAND: &str = "ghc -o /tmp/$fileNameWithoutExt $file && /tmp/$fileNameWithoutExt";
#[cfg(windows)]
const HASKELL_COMMAND: &str =
    "ghc -o \"%TEMP%/zignite-$fileNameWithoutExt.exe\" $file && \"%TEMP%/zignite-$fileNameWithoutExt.exe\"";

#[cfg(unix)]
const JAVA_CLEANUP: &str = "rm -f $dir/$fileNameWithoutExt.class";
#[cfg(windows)]
const JAVA_CLEANUP: &str = "del /Q $dir/$fileNameWithoutExt.class";

fn java_cleanup() -> &'static str {
    JAVA_CLEANUP
}
