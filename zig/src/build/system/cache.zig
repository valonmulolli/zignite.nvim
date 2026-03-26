const std = @import("std");
const bazel = @import("bazel.zig");
const c_family = @import("c_family.zig");
const jvm = @import("jvm.zig");
const node = @import("node.zig");
const python = @import("python.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Query = types.Query;
const Result = types.Result;

const page_allocator = std.heap.page_allocator;

const CacheEntry = struct {
    signature: []u8,
    result: Result,
};

var cache_map: std.StringHashMap(CacheEntry) = .init(page_allocator);

const bazel_markers = &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" };
const jvm_markers = &.{ "pom.xml", "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" };
const node_markers = &.{ "package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock" };
const python_markers = &.{ "pyproject.toml", "uv.lock" };
const c_family_make_markers = &.{"Makefile"};
const c_family_cmake_markers = &.{ "CMakeLists.txt", "build/CMakeCache.txt" };
const c_family_meson_markers = &.{ "meson.build", "build/build.ninja", "build/meson-private/coredata.dat" };

pub fn detect(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    const cache_key = try std.fmt.allocPrint(page_allocator, "{s}\x1f{s}\x1f{s}", .{
        @tagName(query),
        project_root orelse "",
        path,
    });
    errdefer page_allocator.free(cache_key);

    if (cache_map.getPtr(cache_key)) |entry| {
        const current_signature = try buildSignatureAlloc(allocator, query, entry.result);
        defer if (current_signature) |signature| allocator.free(signature);

        if (current_signature) |signature| {
            if (std.mem.eql(u8, signature, entry.signature)) {
                page_allocator.free(cache_key);
                return try cloneResult(allocator, entry.result);
            }
        }
    }

    const fresh = try detectUncached(allocator, query, path, project_root);
    errdefer types.freeOwnedResult(allocator, fresh);

    if (try buildSignatureAlloc(allocator, query, fresh)) |signature| {
        defer allocator.free(signature);
        try storeFreshResult(cache_key, signature, fresh);
    } else {
        page_allocator.free(cache_key);
    }

    return fresh;
}

pub fn resetForTests() void {
    var iterator = cache_map.iterator();
    while (iterator.next()) |entry| {
        page_allocator.free(entry.key_ptr.*);
        page_allocator.free(entry.value_ptr.signature);
        types.freeOwnedResult(page_allocator, entry.value_ptr.result);
    }
    cache_map.clearRetainingCapacity();
}

fn detectUncached(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return switch (query) {
        .c_family => try c_family.detect(allocator, path, project_root),
        .bazel_root => try bazel.detect(allocator, path, project_root),
        .jvm_root => try jvm.detect(allocator, path, project_root),
        .node_root => try node.detect(allocator, path, project_root),
        .python_root => try python.detect(allocator, path, project_root),
    };
}

fn storeFreshResult(cache_key: []u8, signature: []const u8, result: Result) !void {
    const cached_result = try cloneResult(page_allocator, result);
    errdefer types.freeOwnedResult(page_allocator, cached_result);

    const cached_signature = try page_allocator.dupe(u8, signature);
    errdefer page_allocator.free(cached_signature);

    const gop = try cache_map.getOrPut(cache_key);
    if (gop.found_existing) {
        page_allocator.free(cache_key);
        page_allocator.free(gop.value_ptr.signature);
        types.freeOwnedResult(page_allocator, gop.value_ptr.result);
    } else {
        gop.key_ptr.* = cache_key;
    }
    gop.value_ptr.* = .{
        .signature = cached_signature,
        .result = cached_result,
    };
}

fn cloneResult(allocator: std.mem.Allocator, result: Result) !Result {
    var cloned: Result = .{
        .system = result.system,
        .build_ready = result.build_ready,
    };
    errdefer types.freeOwnedResult(allocator, cloned);

    if (result.root) |root| {
        cloned.root = try allocator.dupe(u8, root);
    }

    if (result.commands.len > 0) {
        const commands = try allocator.alloc(types.CommandEntry, result.commands.len);
        errdefer allocator.free(commands);
        for (result.commands, 0..) |entry, index| {
            commands[index] = .{
                .name = entry.name,
                .command = try allocator.dupe(u8, entry.command),
            };
        }
        cloned.commands = commands;
    }

    return cloned;
}

fn buildSignatureAlloc(
    allocator: std.mem.Allocator,
    query: Query,
    result: Result,
) !?[]u8 {
    const root = result.root orelse return null;

    return switch (query) {
        .c_family => blk: {
            const system = result.system orelse break :blk null;
            if (std.mem.eql(u8, system, "make")) {
                break :blk try buildMarkerSignatureAlloc(allocator, root, c_family_make_markers);
            }
            if (std.mem.eql(u8, system, "cmake")) {
                break :blk try buildMarkerSignatureAlloc(allocator, root, c_family_cmake_markers);
            }
            if (std.mem.eql(u8, system, "meson")) {
                break :blk try buildMarkerSignatureAlloc(allocator, root, c_family_meson_markers);
            }
            if (std.mem.eql(u8, system, "bazel")) {
                break :blk try buildMarkerSignatureAlloc(allocator, root, bazel_markers);
            }
            break :blk null;
        },
        .bazel_root => try buildMarkerSignatureAlloc(allocator, root, bazel_markers),
        .jvm_root => try buildMarkerSignatureAlloc(allocator, root, jvm_markers),
        .node_root => try buildMarkerSignatureAlloc(allocator, root, node_markers),
        .python_root => try buildMarkerSignatureAlloc(allocator, root, python_markers),
    };
}

fn buildMarkerSignatureAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    markers: []const []const u8,
) ![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    for (markers, 0..) |marker, index| {
        if (index > 0) try signature.append(allocator, '|');
        try signature.appendSlice(allocator, marker);
        try signature.append(allocator, ':');

        const file_path = try std.fs.path.join(allocator, &.{ root, marker });
        defer allocator.free(file_path);

        const mtime_key = try fileMtimeKeyAlloc(allocator, file_path);
        defer if (mtime_key) |key| allocator.free(key);

        if (mtime_key) |key| {
            try signature.appendSlice(allocator, key);
        } else {
            try signature.appendSlice(allocator, "missing");
        }
    }

    return try signature.toOwnedSlice(allocator);
}

fn fileMtimeKeyAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch return null
    else
        std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = try file.stat();
    return try std.fmt.allocPrint(allocator, "{d}:{d}", .{ stat.size, stat.mtime });
}

test "cached system detection refreshes when the marker signature changes" {
    const allocator = std.testing.allocator;
    resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "Makefile", .data = "run:\n\t@echo run\n" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const first = try detect(allocator, .c_family, filepath, root);
    defer types.freeOwnedResult(allocator, first);
    try std.testing.expectEqualStrings("make run", findCommand(first.commands, "run").?);
    try std.testing.expect(findCommand(first.commands, "test") == null);

    std.time.sleep(2 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "Makefile", .data = "run:\n\t@echo run\ntest:\n\t@echo test\n" });

    const second = try detect(allocator, .c_family, filepath, root);
    defer types.freeOwnedResult(allocator, second);
    try std.testing.expectEqualStrings("make run", findCommand(second.commands, "run").?);
    try std.testing.expectEqualStrings("make test", findCommand(second.commands, "test").?);
}

fn findCommand(commands: []const types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}
