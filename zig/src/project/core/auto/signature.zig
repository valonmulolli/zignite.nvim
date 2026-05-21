const std = @import("std");
const build_common = @import("../../../build/common.zig");
const build_signature = @import("../../../build/signature.zig");
const common = @import("../common.zig");
const project_io = @import("../io.zig");
const make = @import("../../make/api.zig");
const pathing = @import("../../../pathing.zig");
const types = @import("../types.zig");
const build_system = @import("../../../build/system.zig");

const Options = types.Options;

pub fn buildJVMAutoSignatureAlloc(allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildJVMAutoSignatureAllocWithIO(threaded.io(), allocator, result);
}

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

pub fn buildCFamilyAutoSignatureAlloc(
    allocator: std.mem.Allocator,
    options: Options,
    result: build_system.Result,
) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildCFamilyAutoSignatureAllocWithIO(threaded.io(), allocator, options, result);
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
        return try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, make.marker_names);
    }
    if (std.mem.eql(u8, system, "cmake")) {
        return try buildCmakeAutoSignatureAlloc(io, allocator, root);
    }
    if (std.mem.eql(u8, system, "meson")) {
        return try buildMesonAutoSignatureAlloc(io, allocator, root);
    }

    return null;
}

fn buildCmakeAutoSignatureAlloc(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
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

    return try signature.toOwnedSlice(allocator);
}

pub fn buildPythonAutoSignatureAlloc(allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildPythonAutoSignatureAllocWithIO(threaded.io(), allocator, result);
}

pub fn buildPythonAutoSignatureAllocWithIO(io: std.Io, allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    return try build_signature.buildMarkerSignatureAllocWithIO(io, allocator, root, &.{ "pyproject.toml", "uv.lock", "requirements.txt", "environment.yml", "environment.yaml" });
}

pub fn buildBazelAutoSignatureAlloc(allocator: std.mem.Allocator, options: Options, result: build_system.Result) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildBazelAutoSignatureAllocWithIO(threaded.io(), allocator, options, result);
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

    var current_dir = try allocator.dupe(u8, pathing.dirOrDot(normalized_match));
    defer allocator.free(current_dir);

    while (current_dir.len > 0) {
        const build_bazel_path = try std.fs.path.join(allocator, &.{ current_dir, "BUILD.bazel" });
        defer allocator.free(build_bazel_path);
        const build_path = try std.fs.path.join(allocator, &.{ current_dir, "BUILD" });
        defer allocator.free(build_path);

        if (project_io.pathExistsWithIO(io, build_bazel_path)) {
            try build_signature.appendSignatureFileWithIO(io, allocator, &signature, build_bazel_path);
        } else if (project_io.pathExistsWithIO(io, build_path)) {
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
