const std = @import("std");

const BUILD_ARG_PLACEHOLDER = "$zignite_args";

pub const Tool = enum {
    zig,
    go,
    cargo,
    odin,
};

pub const Options = struct {
    tool: Tool,
};

const DetectDaemonRequestHeader = struct {
    request_id: u64,
    tool: Tool,
};

const DETECT_DAEMON_REQ_BEGIN = "@@ZDET_REQ_BEGIN";
const DETECT_DAEMON_REQ_END = "@@ZDET_REQ_END";
const DETECT_DAEMON_RES_BEGIN = "@@ZDET_RES_BEGIN";
const DETECT_DAEMON_RES_END = "@@ZDET_RES_END";
const DETECT_DAEMON_RES_ERR = "@@ZDET_RES_ERR";
const DETECT_DAEMON_MAX_LINE = 4096;

pub fn parseArgs(args: []const []const u8) !Options {
    var tool: ?Tool = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--detect")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--tool=")) {
            tool = try parseTool(arg["--tool=".len..]);
        } else {
            return error.InvalidDetectFlag;
        }
    }

    return .{
        .tool = tool orelse return error.MissingDetectTool,
    };
}

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    const commands = try detectToolCommands(allocator, options.tool);
    defer freeOwnedCommandList(allocator, commands);

    var stdout = std.fs.File.stdout().deprecatedWriter();
    for (commands) |command| {
        try stdout.print("{s}\n", .{command});
    }
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    var reader = std.fs.File.stdin().deprecatedReader();
    var stdout = std.fs.File.stdout().deprecatedWriter();

    while (true) {
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DETECT_DAEMON_MAX_LINE);
        if (maybe_begin == null) {
            break;
        }
        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DETECT_DAEMON_REQ_BEGIN)) {
            continue;
        }

        const header = parseDetectDaemonBegin(begin_line) catch continue;
        var completed = false;

        while (true) {
            const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DETECT_DAEMON_MAX_LINE);
            if (maybe_line == null) {
                break;
            }
            const line_owned = maybe_line.?;
            defer allocator.free(line_owned);
            const line = stripTrailingCR(line_owned);

            if (isDetectDaemonEndLine(line, header.request_id)) {
                completed = true;
                break;
            }
        }

        if (!completed) {
            break;
        }

        try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_BEGIN, header.request_id });
        const detect_result = detectToolCommands(allocator, header.tool);
        if (detect_result) |commands| {
            defer freeOwnedCommandList(allocator, commands);
            for (commands) |command| {
                try stdout.writeByte('\t');
                try stdout.writeAll(command);
                try stdout.writeByte('\n');
            }
        } else |err| {
            try stdout.print("{s} {d} {s}\n", .{ DETECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
        }
        try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_END, header.request_id });
    }
}

pub fn parseTool(value: []const u8) !Tool {
    if (std.ascii.eqlIgnoreCase(value, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(value, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(value, "cargo")) return .cargo;
    if (std.ascii.eqlIgnoreCase(value, "odin")) return .odin;
    return error.InvalidDetectTool;
}

fn parseDetectDaemonBegin(line: []const u8) !DetectDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDetectDaemonHeader;
    if (!std.mem.eql(u8, marker, DETECT_DAEMON_REQ_BEGIN)) {
        return error.InvalidDetectDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDetectDaemonHeader, 10);
    const tool = try parseTool(it.next() orelse return error.InvalidDetectDaemonHeader);
    if (it.next() != null) {
        return error.InvalidDetectDaemonHeader;
    }

    return .{
        .request_id = request_id,
        .tool = tool,
    };
}

fn isDetectDaemonEndLine(line: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, DETECT_DAEMON_REQ_END)) {
        return false;
    }

    const raw_id = it.next() orelse return false;
    if (it.next() != null) {
        return false;
    }
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

pub fn freeOwnedCommandList(allocator: std.mem.Allocator, commands: [][]u8) void {
    for (commands) |command| {
        allocator.free(command);
    }
    allocator.free(commands);
}

pub fn detectToolCommands(allocator: std.mem.Allocator, tool: Tool) ![][]u8 {
    const output = detectToolOutput(allocator, tool) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]u8, 0),
        else => return err,
    };
    defer allocator.free(output);

    const names = try parseDetectCommandNames(allocator, tool, output);
    defer freeOwnedCommandList(allocator, names);

    return try buildDetectCommandRecords(allocator, tool, names);
}

fn detectToolOutput(allocator: std.mem.Allocator, tool: Tool) ![]u8 {
    const argv = switch (tool) {
        .zig => &[_][]const u8{ "zig", "--help" },
        .go => &[_][]const u8{ "go", "help" },
        .cargo => &[_][]const u8{ "cargo", "--list" },
        .odin => &[_][]const u8{ "odin", "help" },
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var merged: std.ArrayList(u8) = .empty;
    errdefer merged.deinit(allocator);

    if (result.stdout.len > 0) {
        try merged.appendSlice(allocator, result.stdout);
    }
    if (result.stderr.len > 0) {
        if (merged.items.len > 0 and merged.items[merged.items.len - 1] != '\n') {
            try merged.append(allocator, '\n');
        }
        try merged.appendSlice(allocator, result.stderr);
    }

    return try merged.toOwnedSlice(allocator);
}

fn parseDetectCommandNames(allocator: std.mem.Allocator, tool: Tool, output: []const u8) ![][]u8 {
    var commands: std.ArrayList([]u8) = .empty;
    errdefer {
        for (commands.items) |command| allocator.free(command);
        commands.deinit(allocator);
    }

    switch (tool) {
        .zig => try parseZigHelpCommandNames(allocator, &commands, output),
        .go => try parseGoHelpCommandNames(allocator, &commands, output),
        .cargo => try parseCargoCommandNames(allocator, &commands, output),
        .odin => try parseOdinCommandNames(allocator, &commands, output),
    }

    return try commands.toOwnedSlice(allocator);
}

fn buildDetectCommandRecords(allocator: std.mem.Allocator, tool: Tool, names: [][]u8) ![][]u8 {
    var commands: std.ArrayList([]u8) = .empty;
    errdefer {
        for (commands.items) |command| allocator.free(command);
        commands.deinit(allocator);
    }

    for (names) |name| {
        const template = try detectCommandTemplate(allocator, tool, name);
        defer allocator.free(template);
        try commands.append(allocator, try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ name, template }));
    }

    return try commands.toOwnedSlice(allocator);
}

fn detectCommandTemplate(allocator: std.mem.Allocator, tool: Tool, name: []const u8) ![]u8 {
    if (tool == .zig) {
        if (std.mem.eql(u8, name, "ast-check")) return allocator.dupe(u8, "zig ast-check $file");
        if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "zig build");
        if (std.mem.eql(u8, name, "build-exe")) return allocator.dupe(u8, "zig build-exe $file");
        if (std.mem.eql(u8, name, "build-lib")) return allocator.dupe(u8, "zig build-lib $file");
        if (std.mem.eql(u8, name, "build-obj")) return allocator.dupe(u8, "zig build-obj $file");
        if (std.mem.eql(u8, name, "env")) return allocator.dupe(u8, "zig env");
        if (std.mem.eql(u8, name, "fetch")) return std.fmt.allocPrint(allocator, "zig fetch {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "fmt")) return allocator.dupe(u8, "zig fmt $file");
        if (std.mem.eql(u8, name, "help")) return allocator.dupe(u8, "zig help");
        if (std.mem.eql(u8, name, "init")) return allocator.dupe(u8, "zig init");
        if (std.mem.eql(u8, name, "libc")) return allocator.dupe(u8, "zig libc");
        if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "zig run $file");
        if (std.mem.eql(u8, name, "std")) return allocator.dupe(u8, "zig std");
        if (std.mem.eql(u8, name, "targets")) return allocator.dupe(u8, "zig targets");
        if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "zig test $file");
        if (std.mem.eql(u8, name, "test-obj")) return allocator.dupe(u8, "zig test-obj $file");
        if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "zig version");
        if (std.mem.eql(u8, name, "zen")) return allocator.dupe(u8, "zig zen");
        return std.fmt.allocPrint(allocator, "zig {s}", .{name});
    }

    if (tool == .go) {
        if (std.mem.eql(u8, name, "bug")) return allocator.dupe(u8, "go bug");
        if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "go build");
        if (std.mem.eql(u8, name, "clean")) return allocator.dupe(u8, "go clean");
        if (std.mem.eql(u8, name, "doc")) return allocator.dupe(u8, "go doc");
        if (std.mem.eql(u8, name, "env")) return allocator.dupe(u8, "go env");
        if (std.mem.eql(u8, name, "fix")) return allocator.dupe(u8, "go fix ./...");
        if (std.mem.eql(u8, name, "fmt")) return allocator.dupe(u8, "go fmt ./...");
        if (std.mem.eql(u8, name, "generate")) return allocator.dupe(u8, "go generate ./...");
        if (std.mem.eql(u8, name, "get")) return allocator.dupe(u8, "go get ./...");
        if (std.mem.eql(u8, name, "install")) return allocator.dupe(u8, "go install ./...");
        if (std.mem.eql(u8, name, "list")) return allocator.dupe(u8, "go list ./...");
        if (std.mem.eql(u8, name, "mod")) return allocator.dupe(u8, "go mod tidy");
        if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "go run .");
        if (std.mem.eql(u8, name, "telemetry")) return allocator.dupe(u8, "go telemetry");
        if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "go test ./...");
        if (std.mem.eql(u8, name, "tool")) return allocator.dupe(u8, "go tool");
        if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "go version");
        if (std.mem.eql(u8, name, "vet")) return allocator.dupe(u8, "go vet ./...");
        if (std.mem.eql(u8, name, "work")) return allocator.dupe(u8, "go work sync");
        return std.fmt.allocPrint(allocator, "go {s}", .{name});
    }

    if (tool == .cargo) {
        if (std.mem.eql(u8, name, "add")) return std.fmt.allocPrint(allocator, "cargo add {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "bench")) return allocator.dupe(u8, "cargo bench");
        if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "cargo build");
        if (std.mem.eql(u8, name, "check")) return allocator.dupe(u8, "cargo check");
        if (std.mem.eql(u8, name, "clean")) return allocator.dupe(u8, "cargo clean");
        if (std.mem.eql(u8, name, "clippy")) return allocator.dupe(u8, "cargo clippy");
        if (std.mem.eql(u8, name, "doc")) return allocator.dupe(u8, "cargo doc --open");
        if (std.mem.eql(u8, name, "fetch")) return allocator.dupe(u8, "cargo fetch");
        if (std.mem.eql(u8, name, "fix")) return allocator.dupe(u8, "cargo fix");
        if (std.mem.eql(u8, name, "generate-lockfile")) return allocator.dupe(u8, "cargo generate-lockfile");
        if (std.mem.eql(u8, name, "init")) return allocator.dupe(u8, "cargo init");
        if (std.mem.eql(u8, name, "install")) return std.fmt.allocPrint(allocator, "cargo install {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "locate-project")) return allocator.dupe(u8, "cargo locate-project");
        if (std.mem.eql(u8, name, "login")) return allocator.dupe(u8, "cargo login");
        if (std.mem.eql(u8, name, "logout")) return allocator.dupe(u8, "cargo logout");
        if (std.mem.eql(u8, name, "metadata")) return allocator.dupe(u8, "cargo metadata");
        if (std.mem.eql(u8, name, "new")) return std.fmt.allocPrint(allocator, "cargo new {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "owner")) return std.fmt.allocPrint(allocator, "cargo owner {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "package")) return allocator.dupe(u8, "cargo package");
        if (std.mem.eql(u8, name, "publish")) return allocator.dupe(u8, "cargo publish");
        if (std.mem.eql(u8, name, "remove")) return std.fmt.allocPrint(allocator, "cargo remove {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "cargo run");
        if (std.mem.eql(u8, name, "rustc")) return allocator.dupe(u8, "cargo rustc");
        if (std.mem.eql(u8, name, "rustdoc")) return allocator.dupe(u8, "cargo rustdoc");
        if (std.mem.eql(u8, name, "search")) return std.fmt.allocPrint(allocator, "cargo search {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "cargo test");
        if (std.mem.eql(u8, name, "tree")) return allocator.dupe(u8, "cargo tree");
        if (std.mem.eql(u8, name, "uninstall")) return std.fmt.allocPrint(allocator, "cargo uninstall {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "update")) return allocator.dupe(u8, "cargo update");
        if (std.mem.eql(u8, name, "vendor")) return allocator.dupe(u8, "cargo vendor");
        if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "cargo version");
        return std.fmt.allocPrint(allocator, "cargo {s}", .{name});
    }

    if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "odin build .");
    if (std.mem.eql(u8, name, "check")) return allocator.dupe(u8, "odin check .");
    if (std.mem.eql(u8, name, "doc")) return allocator.dupe(u8, "odin doc .");
    if (std.mem.eql(u8, name, "query")) return std.fmt.allocPrint(allocator, "odin query {s}", .{BUILD_ARG_PLACEHOLDER});
    if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "odin run .");
    if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "odin test .");
    if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "odin version");
    return std.fmt.allocPrint(allocator, "odin {s}", .{name});
}

fn parseZigHelpCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = stripTrailingCR(raw_line);
        const trimmed = trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "Commands:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "General Options:")) {
            break;
        }

        if (extractCommandToken(trimmed)) |token| {
            try pushUniqueCommand(allocator, commands, token);
        }
    }
}

fn parseGoHelpCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = stripTrailingCR(raw_line);
        const trimmed = trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "The commands are:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "Additional help topics:")) {
            break;
        }
        if (std.mem.startsWith(u8, trimmed, "Use \"go help")) {
            break;
        }

        if (extractCommandToken(trimmed)) |token| {
            if (!std.mem.eql(u8, token, "help")) {
                try pushUniqueCommand(allocator, commands, token);
            }
        }
    }
}

fn parseCargoCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = stripTrailingCR(raw_line);
        const trimmed = trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "Installed Commands:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (extractCommandToken(trimmed)) |token| {
            if (token.len > 1 and !std.mem.eql(u8, token, "help") and !isCargoNoiseLine(trimmed, token)) {
                try pushUniqueCommand(allocator, commands, token);
            }
        }
    }
}

fn parseOdinCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = stripTrailingCR(raw_line);
        const trimmed = trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "Commands:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "Flags:")) {
            break;
        }
        if (std.mem.eql(u8, trimmed, "Example:") or std.mem.eql(u8, trimmed, "Examples:")) {
            break;
        }

        if (extractCommandToken(trimmed)) |token| {
            if (!std.mem.eql(u8, token, "help")) {
                try pushUniqueCommand(allocator, commands, token);
            }
        }
    }
}

fn extractCommandToken(line: []const u8) ?[]const u8 {
    if (line.len == 0) {
        return null;
    }

    var i: usize = 0;
    while (i < line.len and !std.ascii.isWhitespace(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len) {
        return null;
    }
    return line[0..i];
}

fn pushUniqueCommand(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), command: []const u8) !void {
    if (command.len == 0) {
        return;
    }

    for (commands.items) |existing| {
        if (std.mem.eql(u8, existing, command)) {
            return;
        }
    }

    try commands.append(allocator, try allocator.dupe(u8, command));
}

fn isCargoNoiseLine(line: []const u8, token: []const u8) bool {
    _ = token;
    return std.mem.indexOf(u8, line, "alias:") != null or std.mem.indexOf(u8, line, "DEPRECATED:") != null or std.mem.indexOf(u8, line, "REMOVED:") != null;
}

fn trimSpaces(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and std.ascii.isWhitespace(input[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}

test "parse cargo commands skips aliases and removed entries" {
    const allocator = std.testing.allocator;
    const output =
        \\Installed Commands:
        \\    b                    alias: build
        \\    build                Compile a local package and all of its dependencies
        \\    check                Check a local package and all of its dependencies for errors
        \\    git-checkout         REMOVED: This command has been removed
        \\    read-manifest        DEPRECATED: Print a JSON representation of a Cargo.toml manifest.
        \\    rm                   alias: remove
        \\    test                 Execute all unit and integration tests and build examples of a local package
    ;
    const commands = try parseDetectCommandNames(allocator, .cargo, output);
    defer freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqualStrings("build", commands[0]);
    try std.testing.expectEqualStrings("check", commands[1]);
    try std.testing.expectEqualStrings("test", commands[2]);
}

test "detect command records include rendered templates" {
    const allocator = std.testing.allocator;
    const output =
        \\Installed Commands:
        \\    metadata    Output metadata about local package
        \\    run         Run a binary or example of the local package
    ;
    const commands = try detectToolCommandsFromOutput(allocator, .cargo, output);
    defer freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("metadata\tcargo metadata", commands[0]);
    try std.testing.expectEqualStrings("run\tcargo run", commands[1]);
}

fn detectToolCommandsFromOutput(allocator: std.mem.Allocator, tool: Tool, output: []const u8) ![][]u8 {
    const names = try parseDetectCommandNames(allocator, tool, output);
    defer freeOwnedCommandList(allocator, names);
    return try buildDetectCommandRecords(allocator, tool, names);
}

test "parse go commands excludes help and extra topics" {
    const allocator = std.testing.allocator;
    const output =
        \\The commands are:
        \\    build       compile packages and dependencies
        \\    help        Help about any command
        \\    test        test packages
        \\
        \\Additional help topics:
        \\    modules     module support
    ;
    const commands = try parseDetectCommandNames(allocator, .go, output);
    defer freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("build", commands[0]);
    try std.testing.expectEqualStrings("test", commands[1]);
}

test "parse zig commands stops at general options" {
    const allocator = std.testing.allocator;
    const output =
        \\Usage: zig [command] [options]
        \\
        \\Commands:
        \\  build-exe    Build an executable
        \\  fmt          Reformat Zig source into canonical style
        \\
        \\General Options:
        \\  -h, --help   Print command-specific usage
    ;
    const commands = try parseDetectCommandNames(allocator, .zig, output);
    defer freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("build-exe", commands[0]);
    try std.testing.expectEqualStrings("fmt", commands[1]);
}
