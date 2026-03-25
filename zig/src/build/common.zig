const std = @import("std");
const project_common = @import("../project/core/common.zig");

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return project_common.readFileAlloc(allocator, path);
}

pub fn hasCmakeBuildTree(root: []const u8) bool {
    return buildJoinedPathExists(std.heap.page_allocator, root, &.{ "build", "CMakeCache.txt" });
}

pub fn hasMesonBuildTree(root: []const u8) bool {
    if (buildJoinedPathExists(std.heap.page_allocator, root, &.{ "build", "build.ninja" })) {
        return true;
    }
    return buildJoinedPathExists(std.heap.page_allocator, root, &.{ "build", "meson-private", "coredata.dat" });
}

pub fn cmakeBuildCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: ?[]const u8,
) ![]u8 {
    const build_command = if (target) |name|
        try std.fmt.allocPrint(allocator, "cmake --build build --target {s}", .{name})
    else
        try allocator.dupe(u8, "cmake --build build");
    errdefer allocator.free(build_command);

    if (hasCmakeBuildTree(root)) {
        return build_command;
    }

    const setup_command = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1";
    const full_command = try std.fmt.allocPrint(allocator, "{s} && {s}", .{ setup_command, build_command });
    allocator.free(build_command);
    return full_command;
}

pub fn mesonBuildCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: ?[]const u8,
) ![]u8 {
    const build_command = if (target) |name|
        try std.fmt.allocPrint(allocator, "meson compile -C build {s}", .{name})
    else
        try allocator.dupe(u8, "meson compile -C build");
    errdefer allocator.free(build_command);

    if (hasMesonBuildTree(root)) {
        return build_command;
    }

    const setup_command = "meson setup build";
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
    const build_command = try cmakeBuildCommandAlloc(allocator, root, target);
    defer allocator.free(build_command);

    const run_suffix = try buildDiscoveredRunSuffixAlloc(allocator, target, run_path);
    defer allocator.free(run_suffix);

    return try std.fmt.allocPrint(allocator, "{s} && {s}", .{ build_command, run_suffix });
}

pub fn mesonRunCommandAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    const build_command = try mesonBuildCommandAlloc(allocator, root, target);
    defer allocator.free(build_command);

    const run_suffix = try buildDiscoveredRunSuffixAlloc(allocator, target, run_path);
    defer allocator.free(run_suffix);

    return try std.fmt.allocPrint(allocator, "{s} && {s}", .{ build_command, run_suffix });
}

pub fn discoverBuildRunPathAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
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
        const base_path = try std.fmt.allocPrint(allocator, "./build/{s}{s}", .{ prefix, target });
        defer allocator.free(base_path);
        if (buildRelativePathExists(allocator, root, base_path)) {
            return try allocator.dupe(u8, base_path);
        }

        const exe_path = try std.fmt.allocPrint(allocator, "./build/{s}{s}", .{ prefix, target_exe });
        defer allocator.free(exe_path);
        if (buildRelativePathExists(allocator, root, exe_path)) {
            return try allocator.dupe(u8, exe_path);
        }
    }

    const build_dir = try std.fs.path.join(allocator, &.{ root, "build" });
    defer allocator.free(build_dir);

    var dir = if (std.fs.path.isAbsolute(build_dir))
        std.fs.openDirAbsolute(build_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        }
    else
        std.fs.cwd().openDir(build_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (pathContainsIgnoredBuildDir(entry.path)) continue;

        const basename = std.fs.path.basename(entry.path);
        if (!std.mem.eql(u8, basename, target) and !std.mem.eql(u8, basename, target_exe)) {
            continue;
        }

        return try std.fmt.allocPrint(allocator, "./build/{s}", .{entry.path});
    }

    return null;
}

fn buildRelativePathExists(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) bool {
    const full_path = std.fs.path.join(allocator, &.{ root, relative_path }) catch return false;
    defer allocator.free(full_path);

    if (std.fs.path.isAbsolute(full_path)) {
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(full_path, .{}) catch return false;
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

fn buildJoinedPathExists(
    allocator: std.mem.Allocator,
    root: []const u8,
    parts: []const []const u8,
) bool {
    var joined_parts = std.ArrayList([]const u8).empty;
    defer joined_parts.deinit(allocator);
    joined_parts.append(allocator, root) catch return false;
    for (parts) |part| {
        joined_parts.append(allocator, part) catch return false;
    }

    const full_path = std.fs.path.join(allocator, joined_parts.items) catch return false;
    defer allocator.free(full_path);

    if (std.fs.path.isAbsolute(full_path)) {
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}

fn buildDiscoveredRunSuffixAlloc(
    allocator: std.mem.Allocator,
    target: []const u8,
    run_path: ?[]const u8,
) ![]u8 {
    if (run_path) |value| {
        return allocator.dupe(u8, value);
    }

    const target_exe = try std.fmt.allocPrint(allocator, "{s}.exe", .{target});
    defer allocator.free(target_exe);

    const candidate_paths = [_][]const u8{
        try std.fmt.allocPrint(allocator, "./build/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/bin/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/bin/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/Debug/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/Debug/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/Release/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/Release/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/RelWithDebInfo/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/RelWithDebInfo/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/MinSizeRel/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/MinSizeRel/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/bin/Debug/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/bin/Debug/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/bin/Release/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/bin/Release/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/bin/RelWithDebInfo/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/bin/RelWithDebInfo/{s}", .{target_exe}),
        try std.fmt.allocPrint(allocator, "./build/bin/MinSizeRel/{s}", .{target}),
        try std.fmt.allocPrint(allocator, "./build/bin/MinSizeRel/{s}", .{target_exe}),
    };
    defer for (candidate_paths) |candidate| allocator.free(candidate);

    var escaped_candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (escaped_candidates.items) |candidate| allocator.free(candidate);
        escaped_candidates.deinit(allocator);
    }
    for (candidate_paths) |candidate| {
        try escaped_candidates.append(allocator, try project_common.quoteShellArgAlloc(allocator, candidate));
    }

    const quoted_target = try project_common.quoteShellArgAlloc(allocator, target);
    defer allocator.free(quoted_target);
    const quoted_target_exe = try project_common.quoteShellArgAlloc(allocator, target_exe);
    defer allocator.free(quoted_target_exe);
    const quoted_default_path = try project_common.quoteShellArgAlloc(allocator, candidate_paths[0]);
    defer allocator.free(quoted_default_path);

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
        "find build -type f \\( -name {s} -o -name {s} \\) ! -path '*/CMakeFiles/*' ! -path '*/meson-private/*' ! -path '*/meson-logs/*' | head -n 1",
        .{ quoted_target, quoted_target_exe },
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

test "discoverBuildRunPathAlloc prefers common build output directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build/bin");
    try tmp.dir.writeFile(.{
        .sub_path = "build/bin/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const run_path = try discoverBuildRunPathAlloc(allocator, root, "demo-app");
    defer if (run_path) |value| allocator.free(value);

    try std.testing.expect(run_path != null);
    try std.testing.expectEqualStrings("./build/bin/demo-app", run_path.?);
}

test "discoverBuildRunPathAlloc ignores generated build internals" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build/CMakeFiles");
    try tmp.dir.writeFile(.{
        .sub_path = "build/CMakeFiles/demo-app",
        .data = "",
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const run_path = try discoverBuildRunPathAlloc(allocator, root, "demo-app");
    defer if (run_path) |value| allocator.free(value);

    try std.testing.expect(run_path == null);
}

test "cmakeBuildCommandAlloc prepends setup when build tree is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
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

    try tmp.dir.makePath("build");
    try tmp.dir.writeFile(.{
        .sub_path = "build/build.ninja",
        .data = "",
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const command = try mesonBuildCommandAlloc(allocator, root, "demo-app");
    defer allocator.free(command);

    try std.testing.expectEqualStrings("meson compile -C build demo-app", command);
}
