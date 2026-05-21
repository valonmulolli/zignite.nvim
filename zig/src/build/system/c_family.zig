const std = @import("std");
const bazel = @import("bazel.zig");
const common = @import("../common.zig");
const project_common = @import("../../project/core/common.zig");
const task_alias = @import("../../project/core/emit/task_alias.zig");
const make = @import("../../project/make/api.zig");
const project_io = @import("../../project/core/io.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;

const CandidateKind = enum {
    bazel,
    meson,
    cmake,
    make,
};

const RootCandidate = struct {
    kind: CandidateKind,
    root: []u8,
};

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectWithIO(threaded.io(), allocator, path, project_root);
}

pub fn detectWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    const boundary = if (project_root) |root|
        if (root.len > 0) root else null
    else
        null;

    if (try findBestRootCandidateAllocWithIO(io, allocator, path, boundary, 12)) |candidate| {
        defer allocator.free(candidate.root);
        return switch (candidate.kind) {
            .bazel => try bazel.detectWithIO(io, allocator, path, candidate.root),
            .meson => try buildMesonResultWithIO(io, allocator, candidate.root),
            .cmake => try buildCmakeResultWithIO(io, allocator, candidate.root),
            .make => try buildMakeResultWithIO(io, allocator, candidate.root),
        };
    }

    const root = try shared.resolveBaseRoot(allocator, path, project_root);
    return .{ .root = root };
}

fn findBestRootCandidateAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    boundary: ?[]const u8,
    max_up: usize,
) !?RootCandidate {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findBestRootCandidateAllocWithIO(threaded.io(), allocator, path, boundary, max_up);
}

fn findBestRootCandidateAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    boundary: ?[]const u8,
    max_up: usize,
) !?RootCandidate {
    var best_root: ?[]u8 = null;
    errdefer if (best_root) |root| allocator.free(root);
    var best_kind: ?CandidateKind = null;

    const searches = [_]struct {
        kind: CandidateKind,
        markers: []const []const u8,
    }{
        .{ .kind = .bazel, .markers = &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" } },
        .{ .kind = .meson, .markers = &.{"meson.build"} },
        .{ .kind = .cmake, .markers = &.{"CMakeLists.txt"} },
        .{ .kind = .make, .markers = make.marker_names },
    };

    inline for (searches) |search| {
        if (try shared.findRootForFilesWithinAllocWithIO(io, allocator, path, search.markers, boundary, max_up)) |root| {
            if (shared.replaceDeeperOwnedRoot(allocator, &best_root, root)) {
                best_kind = search.kind;
            }
        }
    }

    if (best_root) |root| {
        return .{
            .kind = best_kind.?,
            .root = root,
        };
    }

    return null;
}

fn buildMakeResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildMakeResultWithIO(threaded.io(), allocator, root);
}

fn buildMakeResultWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Result {
    const commands = try buildMakeCommandsAllocWithIO(io, allocator, root);
    return try shared.makeResult(allocator, root, "make", null, commands);
}

fn buildCmakeResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildCmakeResultWithIO(threaded.io(), allocator, root);
}

fn buildCmakeResultWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Result {
    const discovered = try common.discoverCmakeBuildDirAllocWithIO(io, std.heap.page_allocator, root);
    defer if (discovered) |value| std.heap.page_allocator.free(value);
    const build_ready = discovered != null;
    const commands = try buildCmakeCommandsAllocWithIO(io, allocator, root, build_ready);
    return try shared.makeResult(allocator, root, "cmake", build_ready, commands);
}

fn buildMesonResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildMesonResultWithIO(threaded.io(), allocator, root);
}

fn buildMesonResultWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Result {
    const discovered = try common.discoverMesonBuildDirAllocWithIO(io, std.heap.page_allocator, root);
    defer if (discovered) |value| std.heap.page_allocator.free(value);
    const build_ready = discovered != null;
    const commands = try buildMesonCommandsAllocWithIO(io, allocator, root, build_ready);
    return try shared.makeResult(allocator, root, "meson", build_ready, commands);
}

fn buildCmakeCommandsAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildCmakeCommandsAllocWithIO(threaded.io(), allocator, root, build_ready);
}

fn buildCmakeCommandsAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    const build_dir = try common.resolveCmakeBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);
    const shell_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(shell_build_dir);

    try shared.appendOwnedCommandWithAliases(&commands, allocator, "cmake-config", try std.fmt.allocPrint(allocator, "cmake -B {s} -DCMAKE_EXPORT_COMPILE_COMMANDS=1", .{shell_build_dir}), &.{"config"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "cmake-build", try common.cmakeBuildCommandAllocWithIO(io, allocator, root, null), &.{"build"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "cmake-clean", if (build_ready)
        try std.fmt.allocPrint(allocator, "cmake --build {s} --target clean", .{shell_build_dir})
    else
        try std.fmt.allocPrint(allocator, "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- {s}", .{shell_build_dir}), &.{"clean"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "cmake-debug", try std.fmt.allocPrint(
        allocator,
        "cmake -B {s} -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {s}",
        .{ shell_build_dir, shell_build_dir },
    ), &.{"debug"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "cmake-release", try std.fmt.allocPrint(
        allocator,
        "cmake -B {s} -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build {s}",
        .{ shell_build_dir, shell_build_dir },
    ), &.{"release"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "cmake-test", try std.fmt.allocPrint(allocator, "ctest --test-dir {s}", .{shell_build_dir}), &.{"test"});
    try shared.appendOwnedCommand(&commands, allocator, "install", try std.fmt.allocPrint(allocator, "cmake --build {s} --target install", .{shell_build_dir}));

    return try commands.toOwnedSlice(allocator);
}

fn buildMesonCommandsAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildMesonCommandsAllocWithIO(threaded.io(), allocator, root, build_ready);
}

fn buildMesonCommandsAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    const build_dir = try common.resolveMesonBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);
    const shell_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(shell_build_dir);

    try shared.appendOwnedCommandWithAliases(&commands, allocator, "meson-setup", try std.fmt.allocPrint(allocator, "meson setup {s}", .{shell_build_dir}), &.{"setup"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "meson-build", try common.mesonBuildCommandAllocWithIO(io, allocator, root, null), &.{"build"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "meson-clean", if (build_ready)
        try std.fmt.allocPrint(allocator, "meson compile -C {s} --clean", .{shell_build_dir})
    else
        try std.fmt.allocPrint(allocator, "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- {s}", .{shell_build_dir}), &.{"clean"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "meson-test", try std.fmt.allocPrint(allocator, "meson test -C {s}", .{shell_build_dir}), &.{"test"});
    try shared.appendOwnedCommand(&commands, allocator, "install", try std.fmt.allocPrint(allocator, "meson install -C {s}", .{shell_build_dir}));

    return try commands.toOwnedSlice(allocator);
}

fn buildMakeCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildMakeCommandsAllocWithIO(threaded.io(), allocator, root);
}

fn buildMakeCommandsAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    const makefile_path = try findMakefilePathAllocWithIO(io, allocator, root) orelse return try allocator.alloc(CommandEntry, 0);
    defer allocator.free(makefile_path);
    const contents = try common.readFileAllocWithIO(io, allocator, makefile_path);
    defer allocator.free(contents);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    try make.parseTargetsFromFileAllocWithIO(io, allocator, makefile_path, &names);

    try shared.appendOwnedCommand(&commands, allocator, "build", try allocator.dupe(u8, "make"));

    const default_targets = [_][]const u8{ "run", "clean", "test", "install", "debug" };
    for (default_targets) |target| {
        if (!shared.nameListContains(names.items, target)) continue;
        const command = try std.fmt.allocPrint(allocator, "make {s}", .{target});
        try shared.appendOwnedCommand(&commands, allocator, target, command);
    }
    for (task_alias.canonical_aliases) |alias| {
        if (std.mem.eql(u8, alias, "build")) continue;
        if (commandListContains(commands.items, alias)) continue;
        const source_name = task_alias.findSourceName(names.items, alias) orelse continue;
        const command = try std.fmt.allocPrint(allocator, "make {s}", .{source_name});
        try shared.appendOwnedCommand(&commands, allocator, alias, command);
    }

    return try commands.toOwnedSlice(allocator);
}

fn commandListContains(commands: []const CommandEntry, name: []const u8) bool {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "buildMakeCommandsAlloc returns owned empty slice when root has no makefile" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const commands = try buildMakeCommandsAlloc(allocator, root);
    defer allocator.free(commands);

    try std.testing.expectEqual(@as(usize, 0), commands.len);
}

fn findMakefilePathAlloc(allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findMakefilePathAllocWithIO(threaded.io(), allocator, root);
}

fn findMakefilePathAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    for (make.marker_names) |marker| {
        const candidate = try std.fs.path.join(allocator, &.{ root, marker });
        defer allocator.free(candidate);
        if (project_io.pathExistsWithIO(io, candidate)) {
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}
