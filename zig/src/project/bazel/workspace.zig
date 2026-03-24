const std = @import("std");
const common = @import("../core/common.zig");
const project_io = @import("../core/io.zig");
const infer = @import("infer.zig");
const model = @import("model.zig");
const parse = @import("parse.zig");

const CommandEntry = model.CommandEntry;
const CommandInfo = model.CommandInfo;

pub fn buildWorkspaceCommandInfo(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    match_path: ?[]const u8,
) !CommandInfo {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        commands.deinit(allocator);
    }

    if (match_path == null or match_path.?.len == 0) {
        return .{ .commands = try commands.toOwnedSlice(allocator) };
    }

    const normalized_root = try common.normalizePathAlloc(allocator, workspace_root);
    defer allocator.free(normalized_root);

    const normalized_match = try common.normalizePathAlloc(allocator, match_path.?);
    defer allocator.free(normalized_match);

    var current_dir = try allocator.dupe(u8, std.fs.path.dirname(normalized_match) orelse normalized_match);
    defer allocator.free(current_dir);

    var primary_build: ?[]u8 = null;
    var primary_run: ?[]u8 = null;
    var primary_test: ?[]u8 = null;
    errdefer {
        if (primary_build) |value| allocator.free(value);
        if (primary_run) |value| allocator.free(value);
        if (primary_test) |value| allocator.free(value);
    }

    while (current_dir.len > 0) {
        const build_file = try findBuildFileAlloc(allocator, current_dir);
        if (build_file) |path| {
            defer allocator.free(path);

            const contents = common.readFileAlloc(allocator, path) catch continue;
            defer allocator.free(contents);

            const items = try parse.parseTargets(allocator, contents);
            defer model.freeOwnedTargets(allocator, items);

            const package_path = try packagePathFromDirAlloc(allocator, current_dir, normalized_root);
            defer allocator.free(package_path);

            const info = try infer.buildCommandInfo(allocator, items, path, package_path, normalized_match);
            defer model.freeOwnedCommandInfo(allocator, info);

            for (info.commands) |entry| {
                try commands.append(allocator, .{
                    .name = try allocator.dupe(u8, entry.name),
                    .command = try allocator.dupe(u8, entry.command),
                });
            }

            if (info.primary_build) |value| {
                if (primary_build) |existing| allocator.free(existing);
                primary_build = try allocator.dupe(u8, value);
            }
            if (info.primary_run) |value| {
                if (primary_run) |existing| allocator.free(existing);
                primary_run = try allocator.dupe(u8, value);
            }
            if (info.primary_test) |value| {
                if (primary_test) |existing| allocator.free(existing);
                primary_test = try allocator.dupe(u8, value);
            }
        }

        if (std.mem.eql(u8, current_dir, normalized_root)) break;
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;

        allocator.free(current_dir);
        current_dir = try allocator.dupe(u8, parent);
    }

    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .primary_build = primary_build,
        .primary_run = primary_run,
        .primary_test = primary_test,
    };
}

fn findBuildFileAlloc(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const build_bazel = try std.fs.path.join(allocator, &.{ dir, "BUILD.bazel" });
    errdefer allocator.free(build_bazel);
    if (project_io.pathExists(build_bazel)) return build_bazel;
    allocator.free(build_bazel);

    const build = try std.fs.path.join(allocator, &.{ dir, "BUILD" });
    if (project_io.pathExists(build)) return build;
    allocator.free(build);
    return null;
}

fn packagePathFromDirAlloc(allocator: std.mem.Allocator, dir: []const u8, workspace_root: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, workspace_root)) {
        return allocator.dupe(u8, "");
    }
    if (workspace_root.len > 0 and
        dir.len > workspace_root.len and
        std.mem.startsWith(u8, dir, workspace_root) and
        dir[workspace_root.len] == '/')
    {
        return allocator.dupe(u8, dir[workspace_root.len + 1 ..]);
    }
    return allocator.dupe(u8, "");
}
