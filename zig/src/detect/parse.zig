const std = @import("std");
const common = @import("../project/core/common.zig");
const types = @import("types.zig");

const Tool = types.Tool;

pub fn detectToolOutput(allocator: std.mem.Allocator, tool: Tool) ![]u8 {
    if (comptime @import("builtin").is_test) {
        return detectToolOutputWithIO(std.testing.io, allocator, tool);
    }
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return detectToolOutputWithIO(threaded.io(), allocator, tool);
}

pub fn detectToolOutputWithIO(io: std.Io, allocator: std.mem.Allocator, tool: Tool) ![]u8 {
    const argv = switch (tool) {
        .zig => &[_][]const u8{ "zig", "--help" },
        .go => &[_][]const u8{ "go", "help" },
        .cargo => &[_][]const u8{ "cargo", "--list" },
        .odin => &[_][]const u8{ "odin", "help" },
    };

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
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

pub fn parseDetectCommandNames(allocator: std.mem.Allocator, tool: Tool, output: []const u8) ![][]u8 {
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

pub fn stripTrailingCR(line: []const u8) []const u8 {
    return common.stripTrailingCR(line);
}
fn parseZigHelpCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = common.stripTrailingCR(raw_line);
        const trimmed = common.trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "Commands:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "General Options:")) break;

        if (extractCommandToken(trimmed)) |token| {
            try pushUniqueCommand(allocator, commands, token);
        }
    }
}

fn parseGoHelpCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = common.stripTrailingCR(raw_line);
        const trimmed = common.trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "The commands are:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "Additional help topics:")) break;
        if (std.mem.startsWith(u8, trimmed, "Use \"go help")) break;

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
        const line = common.stripTrailingCR(raw_line);
        const trimmed = common.trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "Installed Commands:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (extractCommandToken(trimmed)) |token| {
            if (token.len > 1 and !std.mem.eql(u8, token, "help") and !isCargoNoiseLine(trimmed)) {
                try pushUniqueCommand(allocator, commands, token);
            }
        }
    }
}

fn parseOdinCommandNames(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), output: []const u8) !void {
    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, output, '\n');

    while (lines.next()) |raw_line| {
        const line = common.stripTrailingCR(raw_line);
        const trimmed = common.trimSpaces(line);
        if (!in_commands_section) {
            if (std.mem.eql(u8, trimmed, "Commands:")) {
                in_commands_section = true;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "Flags:")) break;
        if (std.mem.eql(u8, trimmed, "Example:") or std.mem.eql(u8, trimmed, "Examples:")) break;

        if (extractCommandToken(trimmed)) |token| {
            if (!std.mem.eql(u8, token, "help")) {
                try pushUniqueCommand(allocator, commands, token);
            }
        }
    }
}

fn extractCommandToken(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    var i: usize = 0;
    while (i < line.len and !std.ascii.isWhitespace(line[i])) : (i += 1) {}
    if (i == 0) return null;
    return line[0..i];
}

fn pushUniqueCommand(allocator: std.mem.Allocator, commands: *std.ArrayList([]u8), command: []const u8) !void {
    if (command.len == 0) return;

    for (commands.items) |existing| {
        if (std.mem.eql(u8, existing, command)) return;
    }

    const owned_command = try allocator.dupe(u8, command);
    commands.append(allocator, owned_command) catch |err| {
        allocator.free(owned_command);
        return err;
    };
}

fn isCargoNoiseLine(line: []const u8) bool {
    return std.mem.find(u8, line, "alias:") != null or
        std.mem.find(u8, line, "DEPRECATED:") != null or
        std.mem.find(u8, line, "REMOVED:") != null;
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
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqualStrings("build", commands[0]);
    try std.testing.expectEqualStrings("check", commands[1]);
    try std.testing.expectEqualStrings("test", commands[2]);
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
    defer types.freeOwnedCommandList(allocator, commands);

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
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("build-exe", commands[0]);
    try std.testing.expectEqualStrings("fmt", commands[1]);
}
