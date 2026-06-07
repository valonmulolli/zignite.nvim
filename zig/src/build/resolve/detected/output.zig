const std = @import("std");
const build_types = @import("../../system/types.zig");
const types = @import("../types.zig");

pub fn appendImplicitPreferred(
    allocator: std.mem.Allocator,
    preferred: *std.ArrayList(build_types.CommandEntry),
    commands: []const build_types.CommandEntry,
) !void {
    const keys = [_][]const u8{
        "build",
        "run",
        "live",
        "test",
        "clean",
        "install",
        "debug",
        "release",
        "check",
        "lint",
        "fmt",
        "bench",
        "package",
        "dist",
        "bundle",
        "e2e",
        "smoke",
        "integration-test",
    };
    for (keys) |key| {
        if (findCommand(preferred.items, key) != null) continue;
        const command = findCommand(commands, key) orelse continue;
        try upsertOwnedCommand(preferred, allocator, key, command);
    }
}

pub fn findCommand(commands: []const build_types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

pub fn findPreferredCommandName(
    preferred: []const build_types.CommandEntry,
    commands: []const build_types.CommandEntry,
    names: []const []const u8,
) ?[]const u8 {
    for (names) |name| {
        if (findCommand(preferred, name) != null) return name;
    }
    for (names) |name| {
        if (findCommand(commands, name) != null) return name;
    }
    return null;
}

pub fn upsertOwnedCommand(
    commands: *std.ArrayList(build_types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []const u8,
) !void {
    for (commands.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        const owned_command = try allocator.dupe(u8, command);
        allocator.free(entry.command);
        entry.command = owned_command;
        return;
    }

    const owned_name = try allocator.dupe(u8, name);
    const owned_command = allocator.dupe(u8, command) catch |err| {
        allocator.free(owned_name);
        return err;
    };
    commands.append(allocator, .{
        .name = owned_name,
        .command = owned_command,
    }) catch |err| {
        allocator.free(owned_name);
        allocator.free(owned_command);
        return err;
    };
}

pub fn parseProjectOutput(allocator: std.mem.Allocator, output: []const u8) !types.ResolvedOutput {
    var parsed: types.ResolvedOutput = .{};
    errdefer parsed.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "ROOT\t")) {
            parsed.root = try allocator.dupe(u8, line["ROOT\t".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "SYSTEM\t")) {
            parsed.system = try allocator.dupe(u8, line["SYSTEM\t".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "BUILD_READY\t")) {
            parsed.build_ready = std.mem.eql(u8, line["BUILD_READY\t".len..], "1");
            continue;
        }

        const first = splitFirstTab(line) orelse continue;
        if (!std.mem.eql(u8, first[0], "COMMAND") and !std.mem.eql(u8, first[0], "PREFERRED")) continue;
        const second = splitFirstTab(first[1]) orelse continue;
        if (second[0].len == 0 or second[1].len == 0) continue;

        if (std.mem.eql(u8, first[0], "COMMAND")) {
            try upsertOwnedCommand(&parsed.commands, allocator, second[0], second[1]);
        } else {
            try upsertOwnedCommand(&parsed.preferred, allocator, second[0], second[1]);
        }
    }

    return parsed;
}

pub fn resolvedOutputFromSystemResult(
    allocator: std.mem.Allocator,
    result: build_types.Result,
) !types.ResolvedOutput {
    var resolved: types.ResolvedOutput = .{
        .build_ready = result.build_ready,
    };
    errdefer resolved.deinit(allocator);

    if (result.root) |root| {
        resolved.root = try allocator.dupe(u8, root);
    }
    if (result.system) |system| {
        resolved.system = try allocator.dupe(u8, system);
    }
    for (result.commands) |entry| {
        try upsertOwnedCommand(&resolved.commands, allocator, entry.name, entry.command);
    }

    return resolved;
}

pub fn mergeResolvedOutput(
    allocator: std.mem.Allocator,
    base: *types.ResolvedOutput,
    overlay: types.ResolvedOutput,
) !void {
    if (overlay.root) |root| {
        if (base.root) |existing| allocator.free(existing);
        base.root = try allocator.dupe(u8, root);
    }
    if (overlay.system) |system| {
        if (base.system) |existing| allocator.free(existing);
        base.system = try allocator.dupe(u8, system);
    }
    if (overlay.build_ready != null) {
        base.build_ready = overlay.build_ready;
    }
    for (overlay.commands.items) |entry| {
        try upsertOwnedCommand(&base.commands, allocator, entry.name, entry.command);
    }
    for (overlay.preferred.items) |entry| {
        try upsertOwnedCommand(&base.preferred, allocator, entry.name, entry.command);
    }
}

fn splitFirstTab(line: []const u8) ?[2][]const u8 {
    const index = std.mem.findScalar(u8, line, '\t') orelse return null;
    return .{ line[0..index], line[index + 1 ..] };
}

const TestEntry = struct {
    name: []const u8,
    command: []const u8,
};

fn makeEntries(allocator: std.mem.Allocator, defs: []const TestEntry) ![]build_types.CommandEntry {
    var list: std.ArrayList(build_types.CommandEntry) = .empty;
    errdefer {
        for (list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        list.deinit(allocator);
    }
    for (defs) |def| {
        const owned_name = try allocator.dupe(u8, def.name);
        const owned_command = allocator.dupe(u8, def.command) catch |err| {
            allocator.free(owned_name);
            return err;
        };
        try list.append(allocator, .{ .name = owned_name, .command = owned_command });
    }
    return try list.toOwnedSlice(allocator);
}

fn freeEntries(allocator: std.mem.Allocator, entries: []build_types.CommandEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    allocator.free(entries);
}

test "findCommand returns null for empty list and non-matching name" {
    const allocator = std.testing.allocator;
    const entries = try makeEntries(allocator, &.{});
    defer allocator.free(entries);

    try std.testing.expect(findCommand(&.{}, "build") == null);
    try std.testing.expect(findCommand(entries, "build") == null);
}

test "findCommand returns command when name matches" {
    const allocator = std.testing.allocator;
    const entries = try makeEntries(allocator, &.{
        .{ .name = "build", .command = "cargo build" },
        .{ .name = "test", .command = "cargo test" },
    });
    defer freeEntries(allocator, entries);

    try std.testing.expectEqualStrings("cargo build", findCommand(entries, "build").?);
    try std.testing.expectEqualStrings("cargo test", findCommand(entries, "test").?);
    try std.testing.expect(findCommand(entries, "lint") == null);
}

test "findPreferredCommandName prefers preferred list over commands" {
    const allocator = std.testing.allocator;
    const preferred = try makeEntries(allocator, &.{.{ .name = "test", .command = "ctest" }});
    defer freeEntries(allocator, preferred);
    const commands = try makeEntries(allocator, &.{
        .{ .name = "build", .command = "make" },
        .{ .name = "test", .command = "make test" },
    });
    defer freeEntries(allocator, commands);

    try std.testing.expectEqualStrings("test", findPreferredCommandName(preferred, commands, &.{ "build", "test" }).?);
}

test "findPreferredCommandName falls back to commands when not in preferred" {
    const allocator = std.testing.allocator;
    const preferred = try makeEntries(allocator, &.{});
    defer freeEntries(allocator, preferred);
    const commands = try makeEntries(allocator, &.{
        .{ .name = "build", .command = "make" },
    });
    defer freeEntries(allocator, commands);

    try std.testing.expectEqualStrings("build", findPreferredCommandName(preferred, commands, &.{ "build", "test" }).?);
    try std.testing.expect(findPreferredCommandName(preferred, commands, &.{"lint"}) == null);
}

test "upsertOwnedCommand updates existing entry and frees old command" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(build_types.CommandEntry) = .empty;
    defer {
        for (list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        list.deinit(allocator);
    }

    try upsertOwnedCommand(&list, allocator, "build", "old make");
    try upsertOwnedCommand(&list, allocator, "build", "new make");
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("build", list.items[0].name);
    try std.testing.expectEqualStrings("new make", list.items[0].command);
}

test "appendImplicitPreferred adds missing keys from commands list" {
    const allocator = std.testing.allocator;
    const commands = try makeEntries(allocator, &.{
        .{ .name = "build", .command = "make" },
        .{ .name = "test", .command = "make test" },
        .{ .name = "custom", .command = "make custom" },
    });
    defer freeEntries(allocator, commands);

    var preferred: std.ArrayList(build_types.CommandEntry) = .empty;
    defer {
        for (preferred.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        preferred.deinit(allocator);
    }

    try appendImplicitPreferred(allocator, &preferred, commands);
    try std.testing.expect(preferred.items.len >= 2);
    try std.testing.expect(findCommand(preferred.items, "build") != null);
    try std.testing.expect(findCommand(preferred.items, "test") != null);
    try std.testing.expect(findCommand(preferred.items, "custom") == null);
}

test "parseProjectOutput parses full root/system/build-ready/command/preferred lines" {
    const allocator = std.testing.allocator;
    const output = "ROOT\t/project\nSYSTEM\tcmake\nBUILD_READY\t1\nCOMMAND\tbuild\tcmake --build build\nPREFERRED\tbuild\tcmake --build build\nCOMMAND\ttest\tctest\n";
    var parsed = try parseProjectOutput(allocator, output);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("/project", parsed.root.?);
    try std.testing.expectEqualStrings("cmake", parsed.system.?);
    try std.testing.expect(parsed.build_ready.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.preferred.items.len);
    try std.testing.expectEqualStrings("cmake --build build", parsed.commands.items[0].command);
}

test "parseProjectOutput ignores unknown and malformed lines" {
    const allocator = std.testing.allocator;
    const output = "RANDOM\tdata\nCOMMAND\nCOMMAND\tbuild\nCOMMAND\t\t\n";
    var parsed = try parseProjectOutput(allocator, output);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), parsed.commands.items.len);
    try std.testing.expect(parsed.root == null);
    try std.testing.expect(parsed.system == null);
}
