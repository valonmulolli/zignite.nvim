const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseTasks(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    try common.pushUniqueName(allocator, names, "build");
    try common.pushUniqueName(allocator, names, "test");
    try common.pushUniqueName(allocator, names, "clean");

    if (containsSpringBoot(contents)) {
        try common.pushUniqueName(allocator, names, "bootRun");
    }
    if (containsApplicationRun(contents)) {
        try common.pushUniqueName(allocator, names, "run");
    }

    try collectDeclaredTasks(allocator, contents, names);
}

fn containsSpringBoot(contents: []const u8) bool {
    return std.mem.find(u8, contents, "org.springframework.boot") != null;
}

fn containsApplicationRun(contents: []const u8) bool {
    return std.mem.find(u8, contents, "id 'application'") != null
        or std.mem.find(u8, contents, "id \"application\"") != null
        or std.mem.find(u8, contents, "id(\"application\")") != null
        or std.mem.find(u8, contents, "apply plugin: 'application'") != null
        or std.mem.find(u8, contents, "apply plugin: \"application\"") != null
        or std.mem.find(u8, contents, "application {") != null
        or std.mem.find(u8, contents, "application{") != null;
}

fn collectDeclaredTasks(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(common.stripTrailingCR(raw_line));
        if (line.len == 0) continue;

        if (extractQuotedTaskName(line)) |name| {
            try common.pushUniqueName(allocator, names, name);
            continue;
        }

        if (extractRegisteredValueTaskName(line)) |name| {
            try common.pushUniqueName(allocator, names, name);
            continue;
        }

        if (extractBareTaskName(line)) |name| {
            try common.pushUniqueName(allocator, names, name);
        }
    }
}

fn extractQuotedTaskName(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "tasks.register",
        "tasks.create",
        "tasks.named",
        "task(",
    };

    for (prefixes) |prefix| {
        const index = std.mem.find(u8, line, prefix) orelse continue;
        const rest = line[index + prefix.len ..];
        const quote_index = std.mem.findAny(u8, rest, "\"'") orelse continue;
        const quote = rest[quote_index];
        const name_start = quote_index + 1;
        const name_end = std.mem.findScalarPos(u8, rest, name_start, quote) orelse continue;
        const name = rest[name_start..name_end];
        if (name.len == 0) continue;
        return name;
    }

    return null;
}

fn extractRegisteredValueTaskName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "val ")) return null;
    if (std.mem.find(u8, line, " by tasks.") == null and std.mem.find(u8, line, " by tasks") == null) return null;
    if (std.mem.find(u8, line, "register") == null and std.mem.find(u8, line, "create") == null and std.mem.find(u8, line, "named") == null) return null;

    const rest = line["val ".len..];
    const end = scanTaskNameEnd(rest);
    if (end == 0) return null;
    return rest[0..end];
}

fn extractBareTaskName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "task ")) return null;
    const rest = common.trimSpaces(line["task ".len..]);
    if (rest.len == 0) return null;
    if (rest[0] == '"' or rest[0] == '\'') return null;

    const end = scanTaskNameEnd(rest);
    if (end == 0) return null;
    return rest[0..end];
}

fn scanTaskNameEnd(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and isTaskNameChar(text[index])) : (index += 1) {}
    return index;
}

fn isTaskNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ':' or ch == '.';
}

fn containsName(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

test "parse gradle tasks" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(
        allocator,
        \\plugins {
        \\    id("application")
        \\    id("org.springframework.boot") version "3.5.0"
        \\}
    , &names);

    try std.testing.expectEqual(@as(usize, 5), names.items.len);
    try std.testing.expectEqualStrings("build", names.items[0]);
    try std.testing.expectEqualStrings("test", names.items[1]);
    try std.testing.expectEqualStrings("clean", names.items[2]);
    try std.testing.expectEqualStrings("bootRun", names.items[3]);
    try std.testing.expectEqualStrings("run", names.items[4]);
}

test "parse gradle tasks discovers declared tasks across common styles" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(
        allocator,
        \\tasks.register("integrationTest")
        \\tasks.register<Test>("spotlessApply")
        \\tasks.create("bundle")
        \\tasks.named("preview")
        \\val smokeTest by tasks.registering
        \\task e2e(type: Test)
        \\task("dist")
    , &names);

    try std.testing.expect(containsName(names.items, "build"));
    try std.testing.expect(containsName(names.items, "test"));
    try std.testing.expect(containsName(names.items, "clean"));
    try std.testing.expect(containsName(names.items, "integrationTest"));
    try std.testing.expect(containsName(names.items, "spotlessApply"));
    try std.testing.expect(containsName(names.items, "bundle"));
    try std.testing.expect(containsName(names.items, "preview"));
    try std.testing.expect(containsName(names.items, "smokeTest"));
    try std.testing.expect(containsName(names.items, "e2e"));
    try std.testing.expect(containsName(names.items, "dist"));
}
