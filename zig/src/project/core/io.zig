const std = @import("std");
const common = @import("common.zig");
const make = @import("../make/api.zig");
const pathing = @import("../../pathing.zig");
const types = @import("types.zig");

const Kind = types.Kind;

pub fn readProjectFile(allocator: std.mem.Allocator, kind: Kind, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return readProjectFileWithIO(threaded.io(), allocator, kind, path);
}

pub fn readProjectFileWithIO(io: std.Io, allocator: std.mem.Allocator, kind: Kind, path: []const u8) ![]u8 {
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
    if (kind == .zig_auto) {
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
        const makefile_path = try findParentFileAnyAllocWithIO(io, allocator, path, make.marker_names, 12);
        defer if (makefile_path) |value| allocator.free(value);
        if (makefile_path) |value| {
            return common.readFileAllocWithIO(io, allocator, value);
        }
        return allocator.dupe(u8, "");
    }
    if (kind == .package_json_auto) {
        const package_json_path = try findParentFileAllocWithIO(io, allocator, path, "package.json", 12);
        defer if (package_json_path) |value| allocator.free(value);
        if (package_json_path) |value| {
            return common.readFileAllocWithIO(io, allocator, value);
        }
        return allocator.dupe(u8, "");
    }
    return common.readFileAllocWithIO(io, allocator, path);
}

pub fn findParentFileAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    name: []const u8,
    max_up: usize,
) !?[]u8 {
    var current = try std.fmt.allocPrint(
        allocator,
        "{s}",
        .{pathing.dirOrDot(start_path)},
    );
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        const candidate = try std.fs.path.join(allocator, &.{ current, name });
        defer allocator.free(candidate);
        if (pathExistsWithIO(io, candidate)) {
            return try allocator.dupe(u8, candidate);
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try std.fmt.allocPrint(allocator, "{s}", .{parent});
        allocator.free(current);
        current = next;
    }

    return null;
}

pub fn findParentFileAnyAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    names: []const []const u8,
    max_up: usize,
) !?[]u8 {
    var current = try std.fmt.allocPrint(
        allocator,
        "{s}",
        .{pathing.dirOrDot(start_path)},
    );
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        for (names) |name| {
            const candidate = try std.fs.path.join(allocator, &.{ current, name });
            defer allocator.free(candidate);
            if (pathExistsWithIO(io, candidate)) {
                return try allocator.dupe(u8, candidate);
            }
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try std.fmt.allocPrint(allocator, "{s}", .{parent});
        allocator.free(current);
        current = next;
    }

    return null;
}

pub fn pathExistsWithIO(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "findParentFileAlloc walks parents from relative path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/package.json", .data = "{}" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.ts", .{repo_relative});
    defer allocator.free(filepath_relative);
    const package_json_relative = try std.fmt.allocPrint(allocator, "{s}/package.json", .{repo_relative});
    defer allocator.free(package_json_relative);

    const found = try findParentFileAllocWithIO(std.testing.io, allocator, filepath_relative, "package.json", 12);
    defer if (found) |value| allocator.free(value);

    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(package_json_relative, found.?);
}

test "findParentFileAnyAlloc walks parents from relative path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/Makefile", .data = "build:\n\t@true\n" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.c", .{repo_relative});
    defer allocator.free(filepath_relative);
    const makefile_relative = try std.fmt.allocPrint(allocator, "{s}/Makefile", .{repo_relative});
    defer allocator.free(makefile_relative);

    const found = try findParentFileAnyAllocWithIO(std.testing.io, allocator, filepath_relative, &.{ "GNUmakefile", "Makefile" }, 12);
    defer if (found) |value| allocator.free(value);

    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(makefile_relative, found.?);
}
