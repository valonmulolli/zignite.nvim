const std = @import("std");

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const max_bytes = 4 * 1024 * 1024;
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

pub fn freeOwnedNameList(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}

pub fn pushUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    if (value.len == 0) return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try names.append(allocator, try allocator.dupe(u8, value));
}

pub fn trimSpaces(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

pub fn stripTrailingCR(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') {
        return text[0 .. text.len - 1];
    }
    return text;
}

pub fn normalizePathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var prev_was_slash = false;
    for (value) |ch| {
        const mapped = if (ch == '\\') '/' else ch;
        if (mapped == '/') {
            if (prev_was_slash) continue;
            prev_was_slash = true;
        } else {
            prev_was_slash = false;
        }
        try normalized.append(allocator, mapped);
    }
    while (normalized.items.len > 1 and normalized.items[normalized.items.len - 1] == '/') {
        _ = normalized.pop();
    }
    return try normalized.toOwnedSlice(allocator);
}

pub fn makeRelativeToRootAlloc(allocator: std.mem.Allocator, root: []const u8, filepath: []const u8) ![]u8 {
    if (root.len > 0 and std.mem.startsWith(u8, filepath, root)) {
        var start = root.len;
        if (filepath.len > start and filepath[start] == '/') {
            start += 1;
        }
        return try allocator.dupe(u8, filepath[start..]);
    }
    return try allocator.dupe(u8, std.fs.path.basename(filepath));
}

pub fn quoteShellArgAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);

    try quoted.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try quoted.appendSlice(allocator, "'\"'\"'");
        } else {
            try quoted.append(allocator, ch);
        }
    }
    try quoted.append(allocator, '\'');

    return try quoted.toOwnedSlice(allocator);
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

test "quoteShellArgAlloc escapes embedded single quotes" {
    const allocator = std.testing.allocator;
    const quoted = try quoteShellArgAlloc(allocator, "cmd/app's");
    defer allocator.free(quoted);

    try std.testing.expectEqualStrings("'cmd/app'\"'\"'s'", quoted);
}

test "normalizePathAlloc collapses separators and trims trailing slash" {
    const allocator = std.testing.allocator;
    const normalized = try normalizePathAlloc(allocator, "C:\\\\work//demo///src/");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("C:/work/demo/src", normalized);
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
