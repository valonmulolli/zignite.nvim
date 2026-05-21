const std = @import("std");

pub fn findPrimaryTargetName(items: anytype) ?[]const u8 {
    var primary_target: ?[]const u8 = null;
    for (items) |item| {
        if (item.matched and primary_target == null) primary_target = item.name;
    }
    if (primary_target == null and items.len > 0) primary_target = items[0].name;
    return primary_target;
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
        try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const run_path = if (item.artifact_path) |artifact_path|
            try allocator.dupe(u8, artifact_path)
        else
            try discoverRunPathFn(allocator, root, build_dir, item.name);
        defer if (run_path) |value| allocator.free(value);

        const build_command = try buildCommandFn(allocator, root, item.name);
        defer allocator.free(build_command);
        try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ build_label_prefix, item.name, build_command });

        const run_command = try runCommandFn(allocator, root, item.name, run_path);
        defer allocator.free(run_command);
        try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ run_label_prefix, item.name, run_command });

        if (run_path) |value| {
            try stdout.print("RUN_PATH\t{s}\t{s}\n", .{ item.name, value });
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
        try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const run_path = if (item.artifact_path) |artifact_path|
            try allocator.dupe(u8, artifact_path)
        else
            try discoverRunPathFn(io, allocator, root, build_dir, item.name);
        defer if (run_path) |value| allocator.free(value);

        const build_command = try buildCommandFn(allocator, root, item.name);
        defer allocator.free(build_command);
        try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ build_label_prefix, item.name, build_command });

        const run_command = try runCommandFn(allocator, root, item.name, run_path);
        defer allocator.free(run_command);
        try stdout.print("COMMAND\t{s}-{s}\t{s}\n", .{ run_label_prefix, item.name, run_command });

        if (run_path) |value| {
            try stdout.print("RUN_PATH\t{s}\t{s}\n", .{ item.name, value });
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
    try stdout.print("COMMAND\t{s}\t{s}\n", .{ build_label, preferred_build });
    try stdout.print("COMMAND\tbuild\t{s}\n", .{preferred_build});
    try stdout.print("PREFERRED\tbuild\t{s}\n", .{preferred_build});

    try stdout.print("PRIMARY_TARGET\t{s}\n", .{primary_target});
    if (primary_run_path) |value| {
        try stdout.print("PRIMARY_RUN_PATH\t{s}\n", .{value});
    }

    const preferred_run = try runCommandFn(allocator, root, primary_target, primary_run_path);
    defer allocator.free(preferred_run);
    try stdout.print("COMMAND\t{s}\t{s}\n", .{ run_label, preferred_run });
    try stdout.print("COMMAND\trun\t{s}\n", .{preferred_run});
    try stdout.print("PREFERRED\trun\t{s}\n", .{preferred_run});
}
