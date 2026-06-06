const std = @import("std");
const project_common = @import("../project/core/common.zig");

pub fn readFileAllocWithIO(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return project_common.readFileAllocWithIO(io, allocator, path);
}

pub fn hasCmakeBuildTreeWithIO(io: std.Io, root: []const u8) bool {
    const discovered = discoverCmakeBuildDirAllocWithIO(io, std.heap.page_allocator, root) catch return false;
    defer if (discovered) |value| std.heap.page_allocator.free(value);
    return discovered != null;
}

pub fn hasMesonBuildTreeWithIO(io: std.Io, root: []const u8) bool {
    const discovered = discoverMesonBuildDirAllocWithIO(io, std.heap.page_allocator, root) catch return false;
    defer if (discovered) |value| std.heap.page_allocator.free(value);
    return discovered != null;
}

pub fn resolveCmakeBuildDirAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return (try discoverCmakeBuildDirAllocWithIO(io, allocator, root)) orelse allocator.dupe(u8, "build");
}

pub fn resolveMesonBuildDirAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return (try discoverMesonBuildDirAllocWithIO(io, allocator, root)) orelse allocator.dupe(u8, "build");
}

pub fn discoverCmakeBuildDirAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    return try discoverBuildDirForMarkerAllocWithIO(io, allocator, root, "CMakeCache.txt", .file_dir);
}

pub fn discoverMesonBuildDirAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    if (try discoverBuildDirForMarkerAllocWithIO(io, allocator, root, "build.ninja", .file_dir)) |dir| {
        return dir;
    }
    return try discoverBuildDirForMarkerAllocWithIO(io, allocator, root, "coredata.dat", .parent_of_file_dir);
}

pub fn cmakeBuildCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: ?[]const u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return cmakeBuildCommandAllocWithIO(threaded.io(), allocator, root, target);
}

pub fn cmakeBuildCommandAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    target: ?[]const u8,
) ![]u8 {
    const build_dir = try resolveCmakeBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);
    const quoted_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(quoted_build_dir);

    const build_command = if (target) |name| blk: {
        const quoted_target = try project_common.quoteShellArgIfNeededAlloc(allocator, name);
        defer allocator.free(quoted_target);
        break :blk try std.fmt.allocPrint(allocator, "cmake --build {s} --target {s}", .{ quoted_build_dir, quoted_target });
    } else try std.fmt.allocPrint(allocator, "cmake --build {s}", .{quoted_build_dir});
    errdefer allocator.free(build_command);

    const discovered = try discoverCmakeBuildDirAllocWithIO(io, allocator, root);
    defer if (discovered) |value| allocator.free(value);
    if (discovered != null) {
        return build_command;
    }

    const setup_command = try std.fmt.allocPrint(allocator, "cmake -B {s} -DCMAKE_EXPORT_COMPILE_COMMANDS=1", .{quoted_build_dir});
    defer allocator.free(setup_command);
    const full_command = try std.fmt.allocPrint(allocator, "{s} && {s}", .{ setup_command, build_command });
    allocator.free(build_command);
    return full_command;
}

pub fn mesonBuildCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: ?[]const u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return mesonBuildCommandAllocWithIO(threaded.io(), allocator, root, target);
}

pub fn mesonBuildCommandAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    target: ?[]const u8,
) ![]u8 {
    const build_dir = try resolveMesonBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);
    const quoted_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(quoted_build_dir);

    const build_command = if (target) |name| blk: {
        const quoted_target = try project_common.quoteShellArgIfNeededAlloc(allocator, name);
        defer allocator.free(quoted_target);
        break :blk try std.fmt.allocPrint(allocator, "meson compile -C {s} {s}", .{ quoted_build_dir, quoted_target });
    } else try std.fmt.allocPrint(allocator, "meson compile -C {s}", .{quoted_build_dir});
    errdefer allocator.free(build_command);

    const discovered = try discoverMesonBuildDirAllocWithIO(io, allocator, root);
    defer if (discovered) |value| allocator.free(value);
    if (discovered != null) {
        return build_command;
    }

    const setup_command = try std.fmt.allocPrint(allocator, "meson setup {s}", .{quoted_build_dir});
    defer allocator.free(setup_command);
    const full_command = try std.fmt.allocPrint(allocator, "{s} && {s}", .{ setup_command, build_command });
    allocator.free(build_command);
    return full_command;
}

pub fn cmakeRunCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return cmakeRunCommandAllocWithIO(threaded.io(), allocator, root, target, run_path);
}

pub fn cmakeRunCommandAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    const build_command = try cmakeBuildCommandAllocWithIO(io, allocator, root, target);
    defer allocator.free(build_command);

    const build_dir = try resolveCmakeBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);

    const run_suffix = try buildDiscoveredRunSuffixAlloc(allocator, build_dir, target, run_path);
    defer allocator.free(run_suffix);

    return try std.fmt.allocPrint(allocator, "{s} && {s}", .{ build_command, run_suffix });
}

pub fn mesonRunCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return mesonRunCommandAllocWithIO(threaded.io(), allocator, root, target, run_path);
}

pub fn mesonRunCommandAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    const build_command = try mesonBuildCommandAllocWithIO(io, allocator, root, target);
    defer allocator.free(build_command);

    const build_dir = try resolveMesonBuildDirAllocWithIO(io, allocator, root);
    defer allocator.free(build_dir);

    const run_suffix = try buildDiscoveredRunSuffixAlloc(allocator, build_dir, target, run_path);
    defer allocator.free(run_suffix);

    return try std.fmt.allocPrint(allocator, "{s} && {s}", .{ build_command, run_suffix });
}

pub fn discoverBuildRunPathAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_dir: []const u8,
    target: []const u8,
) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return discoverBuildRunPathAllocWithIO(threaded.io(), allocator, root, build_dir, target);
}

pub fn discoverBuildRunPathAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    build_dir: []const u8,
    target: []const u8,
) !?[]u8 {
    if (target.len == 0) return null;

    const target_exe = try std.fmt.allocPrint(allocator, "{s}.exe", .{target});
    defer allocator.free(target_exe);

    const candidate_dirs = [_][]const u8{
        "",
        "bin/",
        "Debug/",
        "Release/",
        "RelWithDebInfo/",
        "MinSizeRel/",
        "bin/Debug/",
        "bin/Release/",
        "bin/RelWithDebInfo/",
        "bin/MinSizeRel/",
    };

    for (candidate_dirs) |prefix| {
        const base_path = try std.fmt.allocPrint(allocator, "./{s}/{s}{s}", .{ build_dir, prefix, target });
        defer allocator.free(base_path);
        if (buildRelativePathExistsWithIO(io, allocator, root, base_path)) {
            return try allocator.dupe(u8, base_path);
        }

        const exe_path = try std.fmt.allocPrint(allocator, "./{s}/{s}{s}", .{ build_dir, prefix, target_exe });
        defer allocator.free(exe_path);
        if (buildRelativePathExistsWithIO(io, allocator, root, exe_path)) {
            return try allocator.dupe(u8, exe_path);
        }
    }

    const build_dir_path = try std.fs.path.join(allocator, &.{ root, build_dir });
    defer allocator.free(build_dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, build_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.depth() > 16) continue;
        if (pathContainsIgnoredBuildDir(entry.path)) continue;

        const basename = std.fs.path.basename(entry.path);
        if (!std.mem.eql(u8, basename, target) and !std.mem.eql(u8, basename, target_exe)) {
            continue;
        }

        return try std.fmt.allocPrint(allocator, "./{s}/{s}", .{ build_dir, entry.path });
    }

    return null;
}

fn buildRelativePathExistsWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) bool {
    const full_path = std.fs.path.join(allocator, &.{ root, relative_path }) catch return false;
    defer allocator.free(full_path);
    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
}

fn pathContainsIgnoredBuildDir(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "CMakeFiles") or std.mem.eql(u8, part, "meson-private") or std.mem.eql(u8, part, "meson-logs")) {
            return true;
        }
    }
    return false;
}

fn buildDiscoveredRunSuffixAlloc(
    allocator: std.mem.Allocator,
    build_dir: []const u8,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    if (run_path) |value| {
        return allocator.dupe(u8, value);
    }

    const target_exe = try std.fmt.allocPrint(allocator, "{s}.exe", .{target});
    defer allocator.free(target_exe);

    var candidate_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidate_paths.items) |c| allocator.free(c);
        candidate_paths.deinit(allocator);
    }
    {
        const subdirs = [_][]const u8{ "", "bin/", "Debug/", "Release/", "RelWithDebInfo/", "MinSizeRel/", "bin/Debug/", "bin/Release/", "bin/RelWithDebInfo/", "bin/MinSizeRel/" };
        for (subdirs) |subdir| {
            try candidate_paths.append(allocator, try std.fmt.allocPrint(allocator, "./{s}/{s}{s}", .{ build_dir, subdir, target }));
            try candidate_paths.append(allocator, try std.fmt.allocPrint(allocator, "./{s}/{s}{s}", .{ build_dir, subdir, target_exe }));
        }
    }

    var escaped_candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (escaped_candidates.items) |candidate| allocator.free(candidate);
        escaped_candidates.deinit(allocator);
    }
    for (candidate_paths.items) |candidate| {
        const escaped = try project_common.quoteShellArgAlloc(allocator, candidate);
        escaped_candidates.append(allocator, escaped) catch |err| {
            allocator.free(escaped);
            return err;
        };
    }

    const quoted_target = try project_common.quoteShellArgAlloc(allocator, target);
    defer allocator.free(quoted_target);
    const quoted_target_exe = try project_common.quoteShellArgAlloc(allocator, target_exe);
    defer allocator.free(quoted_target_exe);
    const quoted_default_path = try project_common.quoteShellArgAlloc(allocator, candidate_paths.items[0]);
    defer allocator.free(quoted_default_path);
    const quoted_build_dir = try project_common.quoteShellArgIfNeededAlloc(allocator, build_dir);
    defer allocator.free(quoted_build_dir);

    var candidate_list: std.ArrayList(u8) = .empty;
    defer candidate_list.deinit(allocator);
    for (escaped_candidates.items, 0..) |candidate, index| {
        if (index > 0) {
            try candidate_list.append(allocator, ' ');
        }
        try candidate_list.appendSlice(allocator, candidate);
    }

    const find_clause = try std.fmt.allocPrint(
        allocator,
        "find {s} -type f \\( -name {s} -o -name {s} \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1",
        .{ quoted_build_dir, quoted_target, quoted_target_exe },
    );
    defer allocator.free(find_clause);

    return try std.fmt.allocPrint(
        allocator,
        "for ZIGNITE_CANDIDATE in {s}; do if [ -x \"$ZIGNITE_CANDIDATE\" ]; then \"$ZIGNITE_CANDIDATE\"; exit $?; fi; done; ZIGNITE_BIN=$({s}) && if [ -n \"$ZIGNITE_BIN\" ] && [ -x \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; elif [ -n \"$ZIGNITE_BIN\" ]; then \"$ZIGNITE_BIN\"; else {s}; fi",
        .{
            candidate_list.items,
            find_clause,
            quoted_default_path,
        },
    );
}

const BuildDirMode = enum {
    file_dir,
    parent_of_file_dir,
};

fn discoverBuildDirForMarkerAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    marker_name: []const u8,
    mode: BuildDirMode,
) !?[]u8 {
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer root_dir.close(io);

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    var best: ?[]u8 = null;
    defer if (best) |value| allocator.free(value);

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), marker_name)) continue;

        const build_dir = switch (mode) {
            .file_dir => std.fs.path.dirname(entry.path) orelse ".",
            .parent_of_file_dir => blk: {
                const file_dir = std.fs.path.dirname(entry.path) orelse ".";
                break :blk std.fs.path.dirname(file_dir) orelse ".";
            },
        };

        if (best) |current| {
            if (!isBetterBuildDir(build_dir, current)) continue;
            allocator.free(current);
        }
        best = try allocator.dupe(u8, build_dir);
    }

    if (best) |value| return try allocator.dupe(u8, value);
    return null;
}

fn isBetterBuildDir(candidate: []const u8, current: []const u8) bool {
    if (std.mem.eql(u8, candidate, "build")) return true;
    if (std.mem.eql(u8, current, "build")) return false;
    if (candidate.len != current.len) return candidate.len < current.len;
    return std.mem.order(u8, candidate, current) == .lt;
}

test "discoverBuildRunPathAlloc prefers common build output directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build/bin");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build/bin/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const run_path = try discoverBuildRunPathAlloc(allocator, root, "build", "demo-app");
    defer if (run_path) |value| allocator.free(value);

    try std.testing.expect(run_path != null);
    try std.testing.expectEqualStrings("./build/bin/demo-app", run_path.?);
}

test "discoverBuildRunPathAlloc ignores generated build internals" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build/CMakeFiles");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build/CMakeFiles/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const run_path = try discoverBuildRunPathAlloc(allocator, root, "build", "demo-app");
    defer if (run_path) |value| allocator.free(value);

    try std.testing.expect(run_path == null);
}

test "cmakeBuildCommandAlloc prepends setup when build tree is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const command = try cmakeBuildCommandAlloc(allocator, root, "demo-app");
    defer allocator.free(command);

    try std.testing.expectEqualStrings(
        "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app",
        command,
    );
}

test "mesonBuildCommandAlloc uses build tree when ready" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build/build.ninja",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const command = try mesonBuildCommandAlloc(allocator, root, "demo-app");
    defer allocator.free(command);

    try std.testing.expectEqualStrings("meson compile -C build demo-app", command);
}

test "cmakeBuildCommandAlloc uses discovered custom build directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build-debug");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build-debug/CMakeCache.txt",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const command = try cmakeBuildCommandAlloc(allocator, root, "demo-app");
    defer allocator.free(command);

    try std.testing.expectEqualStrings("cmake --build build-debug --target demo-app", command);
}

test "cmakeBuildCommandAlloc quotes discovered build directory with spaces" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build debug");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build debug/CMakeCache.txt",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const command = try cmakeBuildCommandAlloc(allocator, root, "demo app");
    defer allocator.free(command);

    try std.testing.expectEqualStrings("cmake --build 'build debug' --target 'demo app'", command);
}

test "mesonBuildCommandAlloc quotes discovered build directory with spaces" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build debug");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build debug/build.ninja",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const command = try mesonBuildCommandAlloc(allocator, root, "demo app");
    defer allocator.free(command);

    try std.testing.expectEqualStrings("meson compile -C 'build debug' 'demo app'", command);
}

test "buildDiscoveredRunSuffix fallback searches discovered build directory" {
    const allocator = std.testing.allocator;

    const command = try buildDiscoveredRunSuffixAlloc(allocator, "build debug", "demo app", null);
    defer allocator.free(command);

    try std.testing.expect(std.mem.find(u8, command, "find 'build debug' -type f") != null);
    try std.testing.expect(std.mem.find(u8, command, "-name 'demo app'") != null);
}

test "discoverBuildRunPathAlloc uses discovered custom build directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build-debug/bin");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build-debug/bin/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const run_path = try discoverBuildRunPathAlloc(allocator, root, "build-debug", "demo-app");
    defer if (run_path) |value| allocator.free(value);

    try std.testing.expect(run_path != null);
    try std.testing.expectEqualStrings("./build-debug/bin/demo-app", run_path.?);
}
