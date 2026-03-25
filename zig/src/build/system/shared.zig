const std = @import("std");
const types = @import("types.zig");

pub fn appendOwnedCommand(
    commands: *std.ArrayList(types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []u8,
) !void {
    try commands.append(allocator, .{ .name = name, .command = command });
}

pub fn appendDupedCommand(
    commands: *std.ArrayList(types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    source_command: []const u8,
) !void {
    try commands.append(allocator, .{
        .name = name,
        .command = try allocator.dupe(u8, source_command),
    });
}

pub fn nameListContains(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

pub fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn pathHasFile(root: []const u8, name: []const u8) bool {
    const full_path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(full_path);

    if (std.fs.path.isAbsolute(full_path)) {
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}

pub fn pathHasAnyMarker(root: []const u8, markers: []const []const u8) bool {
    for (markers) |marker| {
        if (pathHasFile(root, marker)) return true;
    }
    return false;
}

pub fn rootHasAnyMarker(root: []const u8, markers: []const []const u8) bool {
    return pathHasAnyMarker(root, markers);
}

pub fn resolveBaseRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) ![]u8 {
    if (project_root) |root| {
        if (root.len > 0) return allocator.dupe(u8, root);
    }
    return allocator.dupe(u8, std.fs.path.dirname(path) orelse path);
}

pub fn findRootForFilesAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    markers: []const []const u8,
    max_up: usize,
) !?[]u8 {
    var current = try allocator.dupe(u8, std.fs.path.dirname(start_path) orelse start_path);
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (pathHasAnyMarker(current, markers)) {
            return try allocator.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}
