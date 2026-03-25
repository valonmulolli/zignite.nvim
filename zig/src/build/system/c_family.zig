const std = @import("std");
const common = @import("../common.zig");
const make = @import("../../project/make/api.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0) {
            if (shared.rootHasAnyMarker(root, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" })) {
                return .{ .root = try allocator.dupe(u8, root), .system = "bazel" };
            }
            if (shared.rootHasAnyMarker(root, &.{"meson.build"})) {
                return try buildMesonResult(allocator, root);
            }
            if (shared.rootHasAnyMarker(root, &.{"CMakeLists.txt"})) {
                return try buildCmakeResult(allocator, root);
            }
            if (shared.pathHasFile(root, "Makefile")) {
                return try buildMakeResult(allocator, root);
            }
        }
    }

    if (try shared.findRootForFilesAlloc(allocator, path, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }, 12)) |root| {
        return .{ .root = root, .system = "bazel" };
    }
    if (try shared.findRootForFilesAlloc(allocator, path, &.{"meson.build"}, 12)) |root| {
        defer allocator.free(root);
        return try buildMesonResult(allocator, root);
    }
    if (try shared.findRootForFilesAlloc(allocator, path, &.{"CMakeLists.txt"}, 12)) |root| {
        defer allocator.free(root);
        return try buildCmakeResult(allocator, root);
    }
    if (try shared.findRootForFilesAlloc(allocator, path, &.{"Makefile"}, 12)) |root| {
        defer allocator.free(root);
        return try buildMakeResult(allocator, root);
    }

    const root = try shared.resolveBaseRoot(allocator, path, project_root);
    return .{ .root = root };
}

fn buildMakeResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildMakeCommandsAlloc(allocator, root);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "make", .commands = commands };
}

fn buildCmakeResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const build_ready = common.hasCmakeBuildTree(root);
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildCmakeCommandsAlloc(allocator, root, build_ready);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "cmake", .build_ready = build_ready, .commands = commands };
}

fn buildMesonResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const build_ready = common.hasMesonBuildTree(root);
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildMesonCommandsAlloc(allocator, root, build_ready);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "meson", .build_ready = build_ready, .commands = commands };
}

fn buildCmakeCommandsAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const config_command = try allocator.dupe(u8, "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1");
    const build_command = try common.cmakeBuildCommandAlloc(allocator, root, null);
    const clean_command = try allocator.dupe(u8, if (build_ready) "cmake --build build --target clean" else "cmake -E rm -rf build");
    const debug_command = try allocator.dupe(
        u8,
        "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
    );
    const release_command = try allocator.dupe(
        u8,
        "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
    );
    const test_command = try allocator.dupe(u8, "ctest --test-dir build");
    const install_command = try allocator.dupe(u8, "cmake --build build --target install");

    try shared.appendOwnedCommand(&commands, allocator, "cmake-config", config_command);
    try shared.appendOwnedCommand(&commands, allocator, "cmake-build", build_command);
    try shared.appendOwnedCommand(&commands, allocator, "cmake-clean", clean_command);
    try shared.appendOwnedCommand(&commands, allocator, "cmake-debug", debug_command);
    try shared.appendOwnedCommand(&commands, allocator, "cmake-release", release_command);
    try shared.appendOwnedCommand(&commands, allocator, "cmake-test", test_command);
    try shared.appendOwnedCommand(&commands, allocator, "install", install_command);
    try shared.appendDupedCommand(&commands, allocator, "config", config_command);
    try shared.appendDupedCommand(&commands, allocator, "build", build_command);
    try shared.appendDupedCommand(&commands, allocator, "clean", clean_command);
    try shared.appendDupedCommand(&commands, allocator, "debug", debug_command);
    try shared.appendDupedCommand(&commands, allocator, "release", release_command);
    try shared.appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
}

fn buildMesonCommandsAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const setup_command = try allocator.dupe(u8, "meson setup build");
    const build_command = try common.mesonBuildCommandAlloc(allocator, root, null);
    const clean_command = try allocator.dupe(
        u8,
        if (build_ready) "meson compile -C build --clean" else "cmake -E rm -rf build",
    );
    const test_command = try allocator.dupe(u8, "meson test -C build");
    const install_command = try allocator.dupe(u8, "meson install -C build");

    try shared.appendOwnedCommand(&commands, allocator, "meson-setup", setup_command);
    try shared.appendOwnedCommand(&commands, allocator, "meson-build", build_command);
    try shared.appendOwnedCommand(&commands, allocator, "meson-clean", clean_command);
    try shared.appendOwnedCommand(&commands, allocator, "meson-test", test_command);
    try shared.appendOwnedCommand(&commands, allocator, "install", install_command);
    try shared.appendDupedCommand(&commands, allocator, "setup", setup_command);
    try shared.appendDupedCommand(&commands, allocator, "build", build_command);
    try shared.appendDupedCommand(&commands, allocator, "clean", clean_command);
    try shared.appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
}

fn buildMakeCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const makefile_path = try std.fs.path.join(allocator, &.{ root, "Makefile" });
    defer allocator.free(makefile_path);
    const contents = try common.readFileAlloc(allocator, makefile_path);
    defer allocator.free(contents);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    try make.parseTargets(allocator, contents, &names);

    try shared.appendOwnedCommand(&commands, allocator, "build", try allocator.dupe(u8, "make"));

    const default_targets = [_][]const u8{ "run", "clean", "test", "install", "debug" };
    for (default_targets) |target| {
        if (!shared.nameListContains(names.items, target)) continue;
        const command = try std.fmt.allocPrint(allocator, "make {s}", .{target});
        try shared.appendOwnedCommand(&commands, allocator, target, command);
    }

    return try commands.toOwnedSlice(allocator);
}
