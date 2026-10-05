use zignite::detect::{
    command_records, detect_from_output, parse_tool, DetectedCommand, DetectionError, Tool,
};

#[test]
fn parses_supported_tools_case_insensitively() {
    assert_eq!(parse_tool("ZIG"), Ok(Tool::Zig));
    assert_eq!(parse_tool("go"), Ok(Tool::Go));
    assert_eq!(parse_tool("CARGO"), Ok(Tool::Cargo));
    assert_eq!(parse_tool("Odin"), Ok(Tool::Odin));
    assert_eq!(parse_tool("Dart"), Ok(Tool::Dart));
    assert_eq!(parse_tool("SWIFT"), Ok(Tool::Swift));
    assert_eq!(parse_tool("ruby"), Err(DetectionError::InvalidTool));
}

#[test]
fn parses_help_sections_for_all_supported_tools() {
    let cases = [
        (
            Tool::Zig,
            "Commands:\n  build      Build\n  fmt        Format\nGeneral Options:\n",
            vec!["build", "fmt"],
        ),
        (
            Tool::Go,
            "The commands are:\n    build       compile\n    help        help\n    test        test\nAdditional help topics:\n",
            vec!["build", "test"],
        ),
        (
            Tool::Cargo,
            "Installed Commands:\n    build       build\n    rm          alias: remove\n    test        test\n",
            vec!["build", "test"],
        ),
        (
            Tool::Odin,
            "Commands:\n  build      build\n  help       help\nFlags:\n",
            vec!["build"],
        ),
        (
            Tool::Dart,
            "Available commands:\n  analyze    Analyze\n  run        Run\nRun \"dart help <command>\" for more information.\n",
            vec!["analyze", "run"],
        ),
        (
            Tool::Swift,
            "Subcommands:\n  swift build      Build\n  swift run        Run\n  swift test       Test\n",
            vec!["build", "run", "test"],
        ),
    ];

    for (tool, output, expected) in cases {
        let commands =
            detect_from_output(tool, output.as_bytes(), b"", true).expect("help output parses");
        assert_eq!(
            commands
                .iter()
                .map(|command| command.name.as_str())
                .collect::<Vec<_>>(),
            expected
        );
    }
}

#[test]
fn merges_stderr_and_rejects_failed_or_missing_tools() {
    let commands = detect_from_output(
        Tool::Zig,
        b"Usage\nCommands:\n  build Build\n",
        b"General Options:\n",
        true,
    )
    .expect("stdout and stderr are merged");
    assert_eq!(commands[0].name, "build");

    assert_eq!(
        detect_from_output(Tool::Go, b"", b"failed", false),
        Err(DetectionError::CommandFailed { tool: Tool::Go })
    );
    assert_eq!(DetectionError::missing(Tool::Cargo).code(), "MissingTool");
}

#[test]
fn records_use_safe_templates_and_skip_unsafe_names() {
    let names = vec![
        "run".to_owned(),
        "custom;touch".to_owned(),
        "bad\nname".to_owned(),
        "@@ZDET_RES_END".to_owned(),
    ];
    let records = command_records(Tool::Zig, &names);

    assert_eq!(
        records,
        vec![
            DetectedCommand {
                name: "run".to_owned(),
                command: "zig run $file".to_owned(),
            },
            DetectedCommand {
                name: "custom;touch".to_owned(),
                command: "zig 'custom;touch'".to_owned(),
            },
        ]
    );
}
