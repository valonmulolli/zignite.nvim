const std = @import("std");
const common = @import("../core/common.zig");
const file_api = @import("file_api.zig");
const pathing = @import("../../pathing.zig");
const parse = @import("parse.zig");

pub const Target = parse.Target;
pub const freeOwnedTargets = parse.freeOwnedTargets;

pub fn parseTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return parseTargetsWithIO(threaded.io(), allocator, contents, cmake_lists_path, match_path);
}

pub fn parseTargetsWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    contents: []const u8,
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const file_api_targets = file_api.parseTargetsWithIO(io, allocator, cmake_lists_path, match_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (file_api_targets) |items| return items;
    return try parseTargetsFallbackWithIO(io, allocator, contents, cmake_lists_path, match_path, 8);
}

fn parseTargetsFallbackWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    contents: []const u8,
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
    max_depth: usize,
) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |target| freeOwnedTarget(allocator, target);
        targets.deinit(allocator);
    }

    const local_targets = try parse.parseTargets(allocator, contents, cmake_lists_path, match_path);
    try appendOwnedTargets(allocator, &targets, local_targets);

    if (max_depth == 0) return try targets.toOwnedSlice(allocator);

    const subdirs = try parse.collectAddSubdirectoriesAlloc(allocator, contents);
    defer common.freeOwnedNameList(allocator, subdirs);

    const root = pathing.dirOrDot(cmake_lists_path);
    for (subdirs) |subdir| {
        if (std.fs.path.isAbsolute(subdir)) continue;
        const child_path = try std.fs.path.join(allocator, &.{ root, subdir, "CMakeLists.txt" });
        defer allocator.free(child_path);

        const child_contents = common.readFileAllocWithIO(io, allocator, child_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(child_contents);

        const child_targets = try parseTargetsFallbackWithIO(io, allocator, child_contents, child_path, match_path, max_depth - 1);
        try appendOwnedTargets(allocator, &targets, child_targets);
    }

    return try targets.toOwnedSlice(allocator);
}

fn appendOwnedTargets(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(Target),
    items: []Target,
) !void {
    var index: usize = 0;
    errdefer {
        for (items[index..]) |item| freeOwnedTarget(allocator, item);
        allocator.free(items);
    }

    while (index < items.len) : (index += 1) {
        try appendOrMergeOwnedTarget(allocator, targets, items[index]);
    }
    allocator.free(items);
}

fn appendOrMergeOwnedTarget(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(Target),
    incoming: Target,
) !void {
    for (targets.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, incoming.name)) continue;

        existing.matched = existing.matched or incoming.matched;
        if (existing.artifact_path == null and incoming.artifact_path != null) {
            existing.artifact_path = incoming.artifact_path;
            allocator.free(incoming.name);
        } else {
            freeOwnedTarget(allocator, incoming);
        }
        return;
    }

    targets.append(allocator, incoming) catch |err| {
        freeOwnedTarget(allocator, incoming);
        return err;
    };
}

fn freeOwnedTarget(allocator: std.mem.Allocator, target: Target) void {
    allocator.free(target.name);
    if (target.artifact_path) |artifact_path| allocator.free(artifact_path);
}

test "parseTargetsWithIO follows add_subdirectory fallback projects" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data =
        \\project(root)
        \\add_subdirectory(app)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/CMakeLists.txt", .data =
        \\add_executable(child src/main.cpp)
    });

    const root_cmake = try tmp.dir.realPathFileAlloc(std.testing.io, "CMakeLists.txt", allocator);
    defer allocator.free(root_cmake);
    const child_source = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(root_cmake).?, "app", "src", "main.cpp" });
    defer allocator.free(child_source);

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "CMakeLists.txt", allocator, .limited(4096));
    defer allocator.free(contents);

    const targets = try parseTargetsWithIO(std.testing.io, allocator, contents, root_cmake, child_source);
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("child", targets[0].name);
    try std.testing.expect(targets[0].matched);
}
