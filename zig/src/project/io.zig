const std = @import("std");
const common = @import("common.zig");
const types = @import("types.zig");

const Kind = types.Kind;

pub fn readProjectFile(allocator: std.mem.Allocator, kind: Kind, path: []const u8) ![]u8 {
    if (path.len == 0) {
        return allocator.dupe(u8, "");
    }
    if (kind == .system) {
        return allocator.dupe(u8, "");
    }
    if (kind == .bazel_workspace) {
        return allocator.dupe(u8, "");
    }
    if (kind == .bazel_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .jvm_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .c_family_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .cargo_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .go_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .cmake_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .meson_auto) {
        return allocator.dupe(u8, "");
    }
    if (kind == .make_auto) {
        const makefile_path = try findParentFileAlloc(allocator, path, "Makefile", 12);
        defer if (makefile_path) |value| allocator.free(value);
        if (makefile_path) |value| {
            return common.readFileAlloc(allocator, value);
        }
        return allocator.dupe(u8, "");
    }
    if (kind == .package_json_auto) {
        const package_json_path = try findParentFileAlloc(allocator, path, "package.json", 12);
        defer if (package_json_path) |value| allocator.free(value);
        if (package_json_path) |value| {
            return common.readFileAlloc(allocator, value);
        }
        return allocator.dupe(u8, "");
    }
    return common.readFileAlloc(allocator, path);
}

pub fn findParentFileAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    name: []const u8,
    max_up: usize,
) !?[]u8 {
    var current = try allocator.dupe(u8, std.fs.path.dirname(start_path) orelse start_path);
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        const candidate = try std.fs.path.join(allocator, &.{ current, name });
        defer allocator.free(candidate);
        if (pathExists(candidate)) {
            return try allocator.dupe(u8, candidate);
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return null;
}

pub fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
