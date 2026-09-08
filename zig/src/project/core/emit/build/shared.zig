const std = @import("std");
const common = @import("../../common.zig");

pub fn findPrimaryTargetName(items: anytype) ?[]const u8 {
    var exact_target: ?[]const u8 = null;
    var fallback_target: ?[]const u8 = null;
    for (items) |item| {
        if (!item.matched) continue;
        if (item.exact_match) {
            if (exact_target == null) exact_target = item.name;
        } else if (fallback_target == null) {
            fallback_target = item.name;
        }
    }
    if (exact_target) |target| return target;
    if (fallback_target) |target| return target;
    if (items.len > 0) return items[0].name;
    return null;
}

test "findPrimaryTargetName prefers exact matches" {
    const items = [_]struct {
        name: []const u8,
        matched: bool,
        exact_match: bool,
    }{
        .{ .name = "first", .matched = true, .exact_match = false },
        .{ .name = "second", .matched = true, .exact_match = true },
    };

    try std.testing.expectEqualStrings("second", findPrimaryTargetName(&items).?);
}

pub fn emitTargetBuildRunCommands(
    stdout: anytype,
    allocator: std.mem.Allocator,
    items: anytype,
    root: []const u8,
    build_dir: []const u8,
    primary_target: ?[]const u8,
    build_label_prefix: []const u8,
    run_label_prefix: []const u8,
    buildCommandFn: anytype,
    runCommandFn: anytype,
    discoverRunPathFn: anytype,
) !?[]u8 {
    var primary_run_path: ?[]u8 = null;
    errdefer if (primary_run_path) |value| allocator.free(value);

    for (items) |item| {
        if (!common.hasInvalidPayloadChars(item.name)) {
            try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        }
        const run_path = if (item.artifact_path) |artifact_path|
            try allocator.dupe(u8, artifact_path)
        else
            try discoverRunPathFn(allocator, root, build_dir, item.name);
        defer if (run_path) |value| allocator.free(value);

        const build_command = try buildCommandFn(allocator, root, item.name);
        defer allocator.free(build_command);
        if (!common.hasInvalidPayloadChars(build_label_prefix) and
            !common.hasInvalidPayloadChars(item.name) and
            !common.hasInvalidPayloadChars(build_command))
        {
            try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ build_label_prefix, item.name, build_command });
        }

        const run_command = try runCommandFn(allocator, root, item.name, run_path);
        defer allocator.free(run_command);
        if (!common.hasInvalidPayloadChars(run_label_prefix) and
            !common.hasInvalidPayloadChars(item.name) and
            !common.hasInvalidPayloadChars(run_command))
        {
            try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ run_label_prefix, item.name, run_command });
        }

        if (run_path) |value| {
            try common.writeSafeStringRecord(stdout, "RUN_PATH", .{ item.name, value });
            if (primary_target) |target_name| {
                if (primary_run_path == null and std.mem.eql(u8, item.name, target_name)) {
                    primary_run_path = try allocator.dupe(u8, value);
                }
            }
        }
    }

    return primary_run_path;
}

pub fn emitTargetBuildRunCommandsWithIO(
    io: std.Io,
    stdout: anytype,
    allocator: std.mem.Allocator,
    items: anytype,
    root: []const u8,
    build_dir: []const u8,
    primary_target: ?[]const u8,
    build_label_prefix: []const u8,
    run_label_prefix: []const u8,
    buildCommandFn: anytype,
    runCommandFn: anytype,
    discoverRunPathFn: anytype,
) !?[]u8 {
    var primary_run_path: ?[]u8 = null;
    errdefer if (primary_run_path) |value| allocator.free(value);

    for (items) |item| {
        if (!common.hasInvalidPayloadChars(item.name)) {
            try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        }
        const run_path = if (item.artifact_path) |artifact_path|
            try allocator.dupe(u8, artifact_path)
        else
            try discoverRunPathFn(io, allocator, root, build_dir, item.name);
        defer if (run_path) |value| allocator.free(value);

        const build_command = try buildCommandFn(io, allocator, root, item.name);
        defer allocator.free(build_command);
        if (!common.hasInvalidPayloadChars(build_label_prefix) and
            !common.hasInvalidPayloadChars(item.name) and
            !common.hasInvalidPayloadChars(build_command))
        {
            try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ build_label_prefix, item.name, build_command });
        }

        const run_command = try runCommandFn(io, allocator, root, item.name, run_path);
        defer allocator.free(run_command);
        if (!common.hasInvalidPayloadChars(run_label_prefix) and
            !common.hasInvalidPayloadChars(item.name) and
            !common.hasInvalidPayloadChars(run_command))
        {
            try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ run_label_prefix, item.name, run_command });
        }

        if (run_path) |value| {
            try common.writeSafeStringRecord(stdout, "RUN_PATH", .{ item.name, value });
            if (primary_target) |target_name| {
                if (primary_run_path == null and std.mem.eql(u8, item.name, target_name)) {
                    primary_run_path = try allocator.dupe(u8, value);
                }
            }
        }
    }

    return primary_run_path;
}

pub fn emitPrimaryBuildRunCommands(
    stdout: anytype,
    allocator: std.mem.Allocator,
    root: []const u8,
    primary_target: []const u8,
    primary_run_path: ?[]const u8,
    build_label: []const u8,
    run_label: []const u8,
    buildCommandFn: anytype,
    runCommandFn: anytype,
) !void {
    const preferred_build = try buildCommandFn(allocator, root, null);
    defer allocator.free(preferred_build);
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ build_label, preferred_build });
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ "build", preferred_build });
    try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "build", preferred_build });

    try common.writeSafeStringRecord(stdout, "PRIMARY_TARGET", .{primary_target});
    if (primary_run_path) |value| {
        try common.writeSafeStringRecord(stdout, "PRIMARY_RUN_PATH", .{value});
    }

    const preferred_run = try runCommandFn(allocator, root, primary_target, primary_run_path);
    defer allocator.free(preferred_run);
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ run_label, preferred_run });
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ "run", preferred_run });
    try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "run", preferred_run });
}

pub fn emitPrimaryBuildRunCommandsWithIO(
    io: std.Io,
    stdout: anytype,
    allocator: std.mem.Allocator,
    root: []const u8,
    primary_target: []const u8,
    primary_run_path: ?[]const u8,
    build_label: []const u8,
    run_label: []const u8,
    buildCommandFn: anytype,
    runCommandFn: anytype,
) !void {
    const preferred_build = try buildCommandFn(io, allocator, root, null);
    defer allocator.free(preferred_build);
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ build_label, preferred_build });
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ "build", preferred_build });
    try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "build", preferred_build });

    try common.writeSafeStringRecord(stdout, "PRIMARY_TARGET", .{primary_target});
    if (primary_run_path) |value| {
        try common.writeSafeStringRecord(stdout, "PRIMARY_RUN_PATH", .{value});
    }

    const preferred_run = try runCommandFn(io, allocator, root, primary_target, primary_run_path);
    defer allocator.free(preferred_run);
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ run_label, preferred_run });
    try common.writeSafeStringRecord(stdout, "COMMAND", .{ "run", preferred_run });
    try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "run", preferred_run });
}
