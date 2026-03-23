const std = @import("std");
const common = @import("common.zig");

pub const Query = enum {
    c_family,
    bazel_root,
    jvm_root,
};

pub const Result = struct {
    root: ?[]u8 = null,
    system: ?[]const u8 = null,
    build_ready: ?bool = null,
};

pub fn parseQuery(value: []const u8) !Query {
    if (std.ascii.eqlIgnoreCase(value, "c-family")) return .c_family;
    if (std.ascii.eqlIgnoreCase(value, "bazel-root")) return .bazel_root;
    if (std.ascii.eqlIgnoreCase(value, "jvm-root")) return .jvm_root;
    return error.InvalidSystemQuery;
}

pub fn freeOwnedResult(allocator: std.mem.Allocator, result: Result) void {
    if (result.root) |root| allocator.free(root);
}

pub fn detect(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return switch (query) {
        .c_family => try detectCFamily(allocator, path, project_root),
        .bazel_root => try detectBazelRoot(allocator, path, project_root),
        .jvm_root => try detectJvmRoot(allocator, path, project_root),
    };
}

fn detectCFamily(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    const root = try resolveBaseRoot(allocator, path, project_root);
    errdefer allocator.free(root);

    if (rootHasAnyMarker(root, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" })) {
        return .{ .root = root, .system = "bazel" };
    }
    if (rootHasAnyMarker(root, &.{"meson.build"})) {
        return .{ .root = root, .system = "meson", .build_ready = common.hasMesonBuildTree(root) };
    }
    if (rootHasAnyMarker(root, &.{"CMakeLists.txt"})) {
        return .{ .root = root, .system = "cmake", .build_ready = common.hasCmakeBuildTree(root) };
    }
    if (pathHasFile(root, "Makefile")) {
        return .{ .root = root, .system = "make" };
    }

    return .{ .root = root };
}

fn detectBazelRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0 and rootHasAnyMarker(root, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" })) {
            return .{ .root = try allocator.dupe(u8, root), .system = "bazel" };
        }
    }

    if (try findRootForFilesAlloc(allocator, path, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }, 12)) |root| {
        return .{ .root = root, .system = "bazel" };
    }

    return .{};
}

fn detectJvmRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0) {
            if (pathHasFile(root, "pom.xml")) {
                return .{ .root = try allocator.dupe(u8, root), .system = "maven" };
            }
            if (pathHasAnyMarker(root, &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" })) {
                return .{ .root = try allocator.dupe(u8, root), .system = "gradle" };
            }
        }
    }

    if (try findJvmRootAlloc(allocator, path, 12)) |result| {
        return result;
    }

    return .{};
}

fn resolveBaseRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) ![]u8 {
    if (project_root) |root| {
        if (root.len > 0) return allocator.dupe(u8, root);
    }
    return allocator.dupe(u8, std.fs.path.dirname(path) orelse path);
}

fn findRootForFilesAlloc(
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

fn findJvmRootAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    max_up: usize,
) !?Result {
    var current = try allocator.dupe(u8, std.fs.path.dirname(start_path) orelse start_path);
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (pathHasFile(current, "pom.xml")) {
            return .{ .root = try allocator.dupe(u8, current), .system = "maven" };
        }
        if (pathHasAnyMarker(current, &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" })) {
            return .{ .root = try allocator.dupe(u8, current), .system = "gradle" };
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

fn rootHasAnyMarker(root: []const u8, markers: []const []const u8) bool {
    return pathHasAnyMarker(root, markers);
}

fn pathHasAnyMarker(root: []const u8, markers: []const []const u8) bool {
    for (markers) |marker| {
        if (pathHasFile(root, marker)) return true;
    }
    return false;
}

fn pathHasFile(root: []const u8, name: []const u8) bool {
    const full_path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(full_path);

    if (std.fs.path.isAbsolute(full_path)) {
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}

test "detect c family system and build readiness" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build");
    try tmp.dir.writeFile(.{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });
    try tmp.dir.writeFile(.{ .sub_path = "build/CMakeCache.txt", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("cmake", result.system.?);
    try std.testing.expect(result.build_ready.?);
}

test "detect bazel root by walking parents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app");
    try tmp.dir.writeFile(.{ .sub_path = "MODULE.bazel", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.cc" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .bazel_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("bazel", result.system.?);
}

test "detect jvm root and kind" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "gradlew", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "build.gradle.kts", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "Main.kt" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .jvm_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("gradle", result.system.?);
}
