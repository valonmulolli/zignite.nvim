const std = @import("std");

pub fn dirOrDot(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

/// Returns the parent directory of `dir`, or null if already at root.
/// Caller owns the returned memory (allocated via `allocator.dupe`).
pub fn parentDirAlloc(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const parent = std.fs.path.dirname(dir) orelse return null;
    if (std.mem.eql(u8, parent, dir)) return null;
    return try allocator.dupe(u8, parent);
}

/// Walks up parent directories from `start_path` calling `predicate` on each.
/// Returns the first directory where predicate returns true, or null.
/// Caller owns the returned memory.
///
/// `context` is any value forwarded to every predicate invocation.
/// `boundary` — if provided, stops the walk when that directory is reached
/// (exclusive: the boundary directory itself is still checked).
pub fn walkUpwardsAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    max_up: usize,
    boundary: ?[]const u8,
    context: anytype,
    comptime predicate: fn (io: std.Io, allocator: std.mem.Allocator, context: @TypeOf(context), dir: []const u8) anyerror!bool,
) !?[]u8 {
    var current = try allocator.dupe(u8, dirOrDot(start_path));
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (try predicate(io, allocator, context, current)) {
            return try allocator.dupe(u8, current);
        }
        if (boundary) |root| {
            if (std.mem.eql(u8, current, root)) break;
        }
        const next = try parentDirAlloc(allocator, current) orelse break;
        allocator.free(current);
        current = next;
    }
    return null;
}

fn testPredicate(io: std.Io, a: std.mem.Allocator, name: []const u8, dir: []const u8) !bool {
    const full_path = try std.fs.path.join(a, &.{ dir, name });
    defer a.free(full_path);
    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
}

test "walkUpwardsAllocWithIO finds marker in parent directory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{repo_relative});
    defer allocator.free(filepath_relative);

    const marker: []const u8 = "build.zig";
    const found = try walkUpwardsAllocWithIO(
        std.testing.io,
        allocator,
        filepath_relative,
        12,
        null,
        marker,
        testPredicate,
    );
    defer if (found) |value| allocator.free(value);

    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(repo_relative, found.?);
}

test "walkUpwardsAllocWithIO returns null when marker not found" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{repo_relative});
    defer allocator.free(filepath_relative);

    const marker: []const u8 = "nonexistent.txt";
    const found = try walkUpwardsAllocWithIO(
        std.testing.io,
        allocator,
        filepath_relative,
        12,
        null,
        marker,
        testPredicate,
    );

    try std.testing.expect(found == null);
}

test "walkUpwardsAllocWithIO respects boundary" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const src_relative = try std.fmt.allocPrint(allocator, "{s}/src", .{repo_relative});
    defer allocator.free(src_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{repo_relative});
    defer allocator.free(filepath_relative);

    const marker: []const u8 = "build.zig";
    const found = try walkUpwardsAllocWithIO(
        std.testing.io,
        allocator,
        filepath_relative,
        12,
        src_relative,
        marker,
        testPredicate,
    );
    defer if (found) |value| allocator.free(value);

    // Should NOT find it because boundary (src) is checked but then walk stops
    // before reaching the repo directory
    try std.testing.expect(found == null);
}

test "walkUpwardsAllocWithIO respects max_up" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "a/b/c/d/e/f");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a/marker.txt", .data = "found" });

    const a_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/a", .{tmp.sub_path[0..]});
    defer allocator.free(a_relative);
    const f_relative = try std.fmt.allocPrint(allocator, "{s}/b/c/d/e/f", .{a_relative});
    defer allocator.free(f_relative);

    const marker: []const u8 = "marker.txt";
    const found = try walkUpwardsAllocWithIO(
        std.testing.io,
        allocator,
        f_relative,
        2,
        null,
        marker,
        testPredicate,
    );

    try std.testing.expect(found == null);
}

test "dirOrDot uses dot for bare relative paths" {
    try std.testing.expectEqualStrings(".", dirOrDot("main.zig"));
    try std.testing.expectEqualStrings("src", dirOrDot("src/main.zig"));
    try std.testing.expectEqualStrings("/tmp/demo", dirOrDot("/tmp/demo/main.zig"));
}

test "parentDirAlloc returns parent for nested path" {
    const allocator = std.testing.allocator;
    const parent = try parentDirAlloc(allocator, "/tmp/repo/src");
    defer allocator.free(parent.?);
    try std.testing.expectEqualStrings("/tmp/repo", parent.?);
}

test "parentDirAlloc returns null at root" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try parentDirAlloc(allocator, "/"));
    try std.testing.expectEqual(@as(?[]u8, null), try parentDirAlloc(allocator, "."));
}
