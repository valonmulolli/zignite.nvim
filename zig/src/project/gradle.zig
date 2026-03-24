const std = @import("std");
const common = @import("core/common.zig");

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
}

fn containsSpringBoot(contents: []const u8) bool {
    return std.mem.indexOf(u8, contents, "org.springframework.boot") != null;
}

fn containsApplicationRun(contents: []const u8) bool {
    return std.mem.indexOf(u8, contents, "id 'application'") != null
        or std.mem.indexOf(u8, contents, "id \"application\"") != null
        or std.mem.indexOf(u8, contents, "id(\"application\")") != null
        or std.mem.indexOf(u8, contents, "apply plugin: 'application'") != null
        or std.mem.indexOf(u8, contents, "apply plugin: \"application\"") != null
        or std.mem.indexOf(u8, contents, "application {") != null
        or std.mem.indexOf(u8, contents, "application{") != null;
}

test "parse gradle tasks" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);

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
