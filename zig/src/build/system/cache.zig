const std = @import("std");
const bazel = @import("bazel.zig");
const build_common = @import("../common.zig");
const c_family = @import("c_family.zig");
const jvm = @import("jvm.zig");
const make = @import("../../project/make/api.zig");
const node = @import("node.zig");
const python = @import("python.zig");
const build_signature = @import("../signature.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Query = types.Query;
const Result = types.Result;

const page_allocator = std.heap.page_allocator;
const max_cache_entries = 256;

const CacheEntry = struct {
    signature: []u8,
    result: Result,
};

var cache_arena = std.heap.ArenaAllocator.init(page_allocator);
var cache_map: std.StringHashMap(CacheEntry) = undefined;
var cache_initialized = false;

const bazel_markers = bazel.markers;
const jvm_markers = jvm.markers;
const node_markers = node.markers;
const python_markers = python.markers;
const c_family_make_markers = make.marker_names;

pub fn detect(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectWithIO(threaded.io(), allocator, query, path, project_root);
}

pub fn detectWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    ensureCacheInit();

    const cache_key = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{
        @tagName(query),
        project_root orelse "",
        path,
    });
    defer allocator.free(cache_key);

    if (cache_map.getPtr(cache_key)) |entry| {
        const current_signature = try buildSignatureAlloc(io, allocator, query, entry.result);
        defer if (current_signature) |current_sig| allocator.free(current_sig);

        if (current_signature) |current_sig| {
            if (std.mem.eql(u8, current_sig, entry.signature)) {
                return try cloneResult(allocator, entry.result);
            }
        }
    }

    const fresh = try detectUncachedWithIO(io, allocator, query, path, project_root);
    errdefer types.freeOwnedResult(allocator, fresh);

    if (try buildSignatureAlloc(io, allocator, query, fresh)) |fresh_signature| {
        defer allocator.free(fresh_signature);
        try storeFreshResult(cache_key, fresh_signature, fresh);
    }

    return fresh;
}

pub fn resetForTests() void {
    resetCache();
}

fn detectUncached(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectUncachedWithIO(threaded.io(), allocator, query, path, project_root);
}

fn detectUncachedWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return switch (query) {
        .c_family => try c_family.detectWithIO(io, allocator, path, project_root),
        .bazel_root => try bazel.detectWithIO(io, allocator, path, project_root),
        .jvm_root => try jvm.detectWithIO(io, allocator, path, project_root),
        .node_root => try node.detectWithIO(io, allocator, path, project_root),
        .python_root => try python.detectWithIO(io, allocator, path, project_root),
    };
}

fn storeFreshResult(cache_key: []u8, result_signature: []const u8, result: Result) !void {
    ensureCacheInit();

    if (cache_map.get(cache_key) == null and cache_map.count() >= max_cache_entries) {
        resetCache();
        ensureCacheInit();
    }

    const cache_allocator = cache_arena.allocator();
    const owned_key = try cache_allocator.dupe(u8, cache_key);
    const cached_result = try cloneResult(cache_allocator, result);
    const cached_signature = try cache_allocator.dupe(u8, result_signature);

    try cache_map.put(owned_key, .{
        .signature = cached_signature,
        .result = cached_result,
    });
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
        var initialized: usize = 0;
        errdefer {
            for (commands[0..initialized]) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.command);
            }
        }
        for (result.commands, 0..) |entry, index| {
            const owned_name = try allocator.dupe(u8, entry.name);
            const owned_command = allocator.dupe(u8, entry.command) catch |err| {
                allocator.free(owned_name);
                return err;
            };
            commands[index] = .{
                .name = owned_name,
                .command = owned_command,
            };
            initialized += 1;
        }
        cloned.commands = commands;
    }

    return cloned;
}

fn buildSignatureAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    query: Query,
    result: Result,
) !?[]u8 {
    const root = result.root orelse return null;

    return switch (query) {
        .c_family => blk: {
            const system = result.system orelse break :blk null;
            if (std.mem.eql(u8, system, "make")) {
                break :blk try buildMakeSignatureAlloc(io, allocator, root);
            }
            if (std.mem.eql(u8, system, "cmake")) {
                break :blk try buildCmakeSignatureAlloc(io, allocator, root);
            }
            if (std.mem.eql(u8, system, "meson")) {
                break :blk try buildMesonSignatureAlloc(io, allocator, root);
            }
            if (std.mem.eql(u8, system, "bazel")) {
                break :blk try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, bazel_markers);
            }
            break :blk null;
        },
        .bazel_root => try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, bazel_markers),
        .jvm_root => try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, jvm_markers),
        .node_root => try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, node_markers),
        .python_root => try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, python_markers),
    };
}

fn buildMakeSignatureAlloc(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    const makefile_path = try findMakefilePathAlloc(allocator, root) orelse return null;
    defer allocator.free(makefile_path);

    const referenced_files = try make.collectReferencedFilesFromFileAllocWithIO(io, allocator, makefile_path);
    defer {
        for (referenced_files) |path| allocator.free(path);
        allocator.free(referenced_files);
    }

    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    for (referenced_files, 0..) |path, index| {
        if (index == 0) {
            try signature.appendSlice(allocator, "make-includes");
        }
        try build_signature.appendSignatureFileWithIO(io, allocator, &signature, path);
    }

    return try signature.toOwnedSlice(allocator);
}

fn findMakefilePathAlloc(allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    for (c_family_make_markers) |marker| {
        const candidate = try std.fs.path.join(allocator, &.{ root, marker });
        defer allocator.free(candidate);
        if (shared.pathExists(candidate)) {
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}

fn buildCmakeSignatureAlloc(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    const base = try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, &.{"CMakeLists.txt"});
    defer allocator.free(base);
    try signature.appendSlice(allocator, base);

    const build_dir = try build_common.discoverCmakeBuildDirAllocWithIO(io, allocator, root) orelse try allocator.dupe(u8, "build");
    defer allocator.free(build_dir);
    const marker_path = try std.fs.path.join(allocator, &.{ root, build_dir, "CMakeCache.txt" });
    defer allocator.free(marker_path);
    try build_signature.appendSignatureFileWithIO(io, allocator, &signature, marker_path);

    return try signature.toOwnedSlice(allocator);
}

fn buildMesonSignatureAlloc(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    const base = try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, &.{"meson.build"});
    defer allocator.free(base);
    try signature.appendSlice(allocator, base);

    const build_dir = try build_common.discoverMesonBuildDirAllocWithIO(io, allocator, root) orelse try allocator.dupe(u8, "build");
    defer allocator.free(build_dir);

    const ninja_path = try std.fs.path.join(allocator, &.{ root, build_dir, "build.ninja" });
    defer allocator.free(ninja_path);
    try build_signature.appendSignatureFileWithIO(io, allocator, &signature, ninja_path);

    const coredata_path = try std.fs.path.join(allocator, &.{ root, build_dir, "meson-private", "coredata.dat" });
    defer allocator.free(coredata_path);
    try build_signature.appendSignatureFileWithIO(io, allocator, &signature, coredata_path);

    return try signature.toOwnedSlice(allocator);
}

test "cached system detection refreshes when the marker signature changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "run:\n\t@echo run\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const first = try detect(allocator, .c_family, filepath, root);
    defer types.freeOwnedResult(allocator, first);
    try std.testing.expectEqualStrings("make run", findCommand(first.commands, "run").?);
    try std.testing.expect(findCommand(first.commands, "test") == null);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "run:\n\t@echo run\ntest:\n\t@echo test\n" });

    const second = try detect(allocator, .c_family, filepath, root);
    defer types.freeOwnedResult(allocator, second);
    try std.testing.expectEqualStrings("make run", findCommand(second.commands, "run").?);
    try std.testing.expectEqualStrings("make test", findCommand(second.commands, "test").?);
}

test "cached make detection refreshes when included makefile changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data =
        \\include targets.mk
        \\run:
        \\\t@echo run
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "targets.mk", .data =
        \\build:
        \\\t@echo build
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const first = try detect(allocator, .c_family, filepath, root);
    defer types.freeOwnedResult(allocator, first);
    try std.testing.expect(findCommand(first.commands, "test") == null);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "targets.mk", .data =
        \\build:
        \\\t@echo build
        \\test:
        \\\t@echo test
    });

    const second = try detect(allocator, .c_family, filepath, root);
    defer types.freeOwnedResult(allocator, second);
    try std.testing.expectEqualStrings("make test", findCommand(second.commands, "test").?);
}

fn findCommand(commands: []const types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

fn ensureCacheInit() void {
    if (cache_initialized) return;
    cache_map = std.StringHashMap(CacheEntry).init(cache_arena.allocator());
    cache_initialized = true;
}

fn resetCache() void {
    if (!cache_initialized) return;
    cache_map.deinit();
    cache_arena.deinit();
    cache_arena = std.heap.ArenaAllocator.init(page_allocator);
    cache_map = std.StringHashMap(CacheEntry).init(cache_arena.allocator());
    cache_initialized = true;
}
