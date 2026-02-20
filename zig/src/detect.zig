const std = @import("std");

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

        const commands = detectToolCommands(allocator, header.tool) catch try allocator.alloc([]u8, 0);
        defer freeOwnedCommandList(allocator, commands);

        try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_BEGIN, header.request_id });
        for (commands) |command| {
            try stdout.writeByte('\t');
            try stdout.writeAll(command);
            try stdout.writeByte('\n');
        }
        try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_END, header.request_id });
    }
}

fn parseTool(value: []const u8) !Tool {
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

fn freeOwnedCommandList(allocator: std.mem.Allocator, commands: [][]u8) void {
    for (commands) |command| {
        allocator.free(command);
    }
    allocator.free(commands);
}

fn detectToolCommands(allocator: std.mem.Allocator, tool: Tool) ![][]u8 {
    const output = detectToolOutput(allocator, tool) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]u8, 0),
        else => return err,
    };
    defer allocator.free(output);

    return try parseDetectCommandNames(allocator, tool, output);
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
            if (token.len > 1 and !std.mem.eql(u8, token, "help")) {
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

fn trimSpaces(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and std.ascii.isWhitespace(input[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}
