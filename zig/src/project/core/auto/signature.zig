const std = @import("std");
const build_common = @import("../../../build/common.zig");
const build_signature = @import("../../../build/signature.zig");
const cmake_parse = @import("../../cmake/parse.zig");
const common = @import("../common.zig");
const make = @import("../../make/api.zig");
const pathing = @import("../../../pathing.zig");
const types = @import("../types.zig");
const build_system = @import("../../../build/system.zig");

const Options = types.Options;
const MAX_CMAKE_SIGNATURE_DEPTH: usize = 8;
const MAX_CMAKE_SIGNATURE_FILES: usize = 256;

pub fn buildJVMAutoSignatureAllocWithIO(io: std.Io, allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    const system = result.system orelse return null;

    if (std.mem.eql(u8, system, "maven")) {
        return try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, &.{"pom.xml"});
    }
    if (std.mem.eql(u8, system, "gradle")) {
        return try build_signature.buildMarkerSignatureAllocWithIO(
            io,
            allocator,
            root,
            &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" },
        );
    }

    return null;
}

pub fn buildCFamilyAutoSignatureAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    result: build_system.Result,
) !?[]u8 {
    const root = result.root orelse return null;
    const system = result.system orelse return null;

    if (std.mem.eql(u8, system, "bazel")) {
        return try buildBazelAutoSignatureAllocWithIO(io, allocator, options, result);
    }
    if (std.mem.eql(u8, system, "make")) {
        return try buildMakeAutoSignatureAllocWithIO(io, allocator, root);
    }
    if (std.mem.eql(u8, system, "cmake")) {
        return try buildCmakeAutoSignatureAlloc(io, allocator, root);
    }
    if (std.mem.eql(u8, system, "meson")) {
        return try buildMesonAutoSignatureAlloc(io, allocator, root);
    }

    return null;
}

fn buildMakeAutoSignatureAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const makefile_path = try findMakefilePathAllocWithIO(io, allocator, root) orelse {
        return try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, make.marker_names);
    };
    defer allocator.free(makefile_path);

    const referenced_files = try make.collectReferencedFilesFromFileAllocWithIO(io, allocator, makefile_path);
    defer {
        for (referenced_files) |path| allocator.free(path);
        allocator.free(referenced_files);
    }

    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    for (referenced_files, 0..) |path, index| {
        if (index == 0) try signature.appendSlice(allocator, "make-includes");
        try build_signature.appendSignatureFileWithIO(io, allocator, &signature, path);
    }

    return try signature.toOwnedSlice(allocator);
}

fn findMakefilePathAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    for (make.marker_names) |marker| {
        const candidate = try std.fs.path.join(allocator, &.{ root, marker });
        defer allocator.free(candidate);
        if (common.isRegularFileWithIO(io, candidate)) {
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}

fn buildCmakeAutoSignatureAlloc(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    const base = try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, &.{"CMakeLists.txt"});
    defer allocator.free(base);
    try signature.appendSlice(allocator, base);
    try appendCmakeSourceSignaturesWithIO(io, allocator, &signature, root);

    const build_dir = try build_common.discoverCmakeBuildDirAllocWithIO(io, allocator, root) orelse try allocator.dupe(u8, "build");
    defer allocator.free(build_dir);
    const marker_path = try std.fs.path.join(allocator, &.{ root, build_dir, "CMakeCache.txt" });
    defer allocator.free(marker_path);
    try build_signature.appendSignatureFileWithIO(io, allocator, &signature, marker_path);
    try appendCmakeReplySignaturesWithIO(io, allocator, &signature, root, build_dir);

    return try signature.toOwnedSlice(allocator);
}

fn buildMesonAutoSignatureAlloc(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
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

    const intro_targets_path = try std.fs.path.join(allocator, &.{ root, build_dir, "meson-info", "intro-targets.json" });
    defer allocator.free(intro_targets_path);
    try build_signature.appendSignatureFileWithIO(io, allocator, &signature, intro_targets_path);

    return try signature.toOwnedSlice(allocator);
}

fn appendCmakeReplySignaturesWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    signature: *std.ArrayList(u8),
    root: []const u8,
    build_dir: []const u8,
) !void {
    const reply_dir = try std.fs.path.join(allocator, &.{ root, build_dir, ".cmake", "api", "v1", "reply" });
    defer allocator.free(reply_dir);

    var dir = std.Io.Dir.cwd().openDir(io, reply_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = try allocator.dupe(u8, entry.name);
        names.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names.items) |name| {
        const path = try std.fs.path.join(allocator, &.{ reply_dir, name });
        defer allocator.free(path);
        try build_signature.appendSignatureFileWithIO(io, allocator, signature, path);
    }
}

fn appendCmakeSourceSignaturesWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    signature: *std.ArrayList(u8),
    root: []const u8,
) !void {
    const root_path = try std.fs.path.join(allocator, &.{ root, "CMakeLists.txt" });
    defer allocator.free(root_path);
    const root_contents = common.readFileAllocWithIO(io, allocator, root_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer allocator.free(root_contents);

    var visited: std.ArrayList([]u8) = .empty;
    defer {
        for (visited.items) |path| allocator.free(path);
        visited.deinit(allocator);
    }
    const normalized_root_path = try common.normalizePathAlloc(allocator, root_path);
    defer allocator.free(normalized_root_path);
    const owned_root_path = try allocator.dupe(u8, normalized_root_path);
    visited.append(allocator, owned_root_path) catch |err| {
        allocator.free(owned_root_path);
        return err;
    };

    try appendCmakeChildSignaturesWithIO(io, allocator, signature, root_path, root_contents, &visited, 0);
}

fn appendCmakeChildSignaturesWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    signature: *std.ArrayList(u8),
    current_path: []const u8,
    contents: []const u8,
    visited: *std.ArrayList([]u8),
    depth: usize,
) !void {
    if (depth >= MAX_CMAKE_SIGNATURE_DEPTH or visited.items.len >= MAX_CMAKE_SIGNATURE_FILES) return;

    const subdirs = try cmake_parse.collectAddSubdirectoriesAlloc(allocator, contents);
    defer common.freeOwnedNameList(allocator, subdirs);

    const current_dir = std.fs.path.dirname(current_path) orelse ".";
    for (subdirs) |subdir| {
        if (std.fs.path.isAbsolute(subdir) or common.hasInvalidPayloadChars(subdir)) continue;

        const child_path = try std.fs.path.join(allocator, &.{ current_dir, subdir, "CMakeLists.txt" });
        defer allocator.free(child_path);
        if (!common.isRegularFileWithIO(io, child_path)) continue;

        const normalized_child_path = try common.normalizePathAlloc(allocator, child_path);
        defer allocator.free(normalized_child_path);
        var already_seen = false;
        for (visited.items) |existing| {
            if (std.mem.eql(u8, existing, normalized_child_path)) {
                already_seen = true;
                break;
            }
        }
        if (already_seen or visited.items.len >= MAX_CMAKE_SIGNATURE_FILES) continue;

        const owned_child_path = try allocator.dupe(u8, normalized_child_path);
        visited.append(allocator, owned_child_path) catch |err| {
            allocator.free(owned_child_path);
            return err;
        };
        try build_signature.appendSignatureFileWithIO(io, allocator, signature, child_path);

        const child_contents = common.readFileAllocWithIO(io, allocator, child_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer allocator.free(child_contents);
        try appendCmakeChildSignaturesWithIO(
            io,
            allocator,
            signature,
            child_path,
            child_contents,
            visited,
            depth + 1,
        );
    }
}

test "cmake auto signature tracks file API reply changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build/.cmake/api/v1/reply");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/CMakeCache.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build/.cmake/api/v1/reply/index-1.json",
        .data = "{}",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const first = try buildCmakeAutoSignatureAlloc(std.testing.io, allocator, root);
    defer allocator.free(first);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build/.cmake/api/v1/reply/index-1.json",
        .data = "{\"reply\":{}}",
    });

    const second = try buildCmakeAutoSignatureAlloc(std.testing.io, allocator, root);
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "cmake auto signature tracks nested CMakeLists changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "CMakeLists.txt",
        .data = "project(demo)\nadd_subdirectory(app)\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app/CMakeLists.txt",
        .data = "add_executable(app main.cpp)\n",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const first = try buildCmakeAutoSignatureAlloc(std.testing.io, allocator, root);
    defer allocator.free(first);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app/CMakeLists.txt",
        .data = "add_executable(app main.cpp)\nadd_executable(cli cli.cpp)\n",
    });

    const second = try buildCmakeAutoSignatureAlloc(std.testing.io, allocator, root);
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

pub fn buildPythonAutoSignatureAllocWithIO(io: std.Io, allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    return try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, &.{ "pyproject.toml", "uv.lock", "requirements.txt", "environment.yml", "environment.yaml" });
}

pub fn buildBazelAutoSignatureAllocWithIO(io: std.Io, allocator: std.mem.Allocator, options: Options, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    const match_path = options.match_path orelse options.path;

    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    const workspace_signature = try build_signature.buildMarkerSignatureAllocWithIO(
        io,
        allocator,
        root,
        &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" },
    );
    defer allocator.free(workspace_signature);
    try signature.appendSlice(allocator, workspace_signature);

    const normalized_root = try common.normalizePathAlloc(allocator, root);
    defer allocator.free(normalized_root);
    const normalized_match = try common.normalizePathAlloc(allocator, match_path);
    defer allocator.free(normalized_match);

    if (!common.isPathWithinRoot(normalized_root, normalized_match)) {
        return try signature.toOwnedSlice(allocator);
    }

    var current_dir = try allocator.dupe(u8, pathing.dirOrDot(normalized_match));
    defer allocator.free(current_dir);

    while (current_dir.len > 0) {
        const build_bazel_path = try std.fs.path.join(allocator, &.{ current_dir, "BUILD.bazel" });
        defer allocator.free(build_bazel_path);
        const build_path = try std.fs.path.join(allocator, &.{ current_dir, "BUILD" });
        defer allocator.free(build_path);

        if (common.isRegularFileWithIO(io, build_bazel_path)) {
            try build_signature.appendSignatureFileWithIO(io, allocator, &signature, build_bazel_path);
        } else if (common.isRegularFileWithIO(io, build_path)) {
            try build_signature.appendSignatureFileWithIO(io, allocator, &signature, build_path);
        }

        if (std.mem.eql(u8, current_dir, normalized_root)) break;
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;

        const next = try std.fmt.allocPrint(allocator, "{s}", .{parent});
        allocator.free(current_dir);
        current_dir = next;
    }

    return try signature.toOwnedSlice(allocator);
}
