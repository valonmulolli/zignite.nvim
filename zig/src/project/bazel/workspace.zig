const std = @import("std");
const common = @import("../core/common.zig");
const pathing = @import("../../pathing.zig");
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
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildWorkspaceCommandInfoWithIO(threaded.io(), allocator, workspace_root, match_path);
}

pub fn buildWorkspaceCommandInfoWithIO(
    io: std.Io,
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

    var current_dir = try std.fmt.allocPrint(
        allocator,
        "{s}",
        .{pathing.dirOrDot(normalized_match)},
    );
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
        const build_file = try findBuildFileAllocWithIO(io, allocator, current_dir);
        if (build_file) |path| {
            defer allocator.free(path);

            const contents = common.readFileAllocWithIO(io, allocator, path) catch continue;
            defer allocator.free(contents);

            const items = try parse.parseTargets(allocator, contents);
            defer model.freeOwnedTargets(allocator, items);

            const package_path = try packagePathFromDirAlloc(allocator, current_dir, normalized_root);
            defer allocator.free(package_path);

            const info = try infer.buildCommandInfo(allocator, items, path, package_path, normalized_match);
            defer model.freeOwnedCommandInfo(allocator, info);

            for (info.commands) |entry| {
                const owned_name = try allocator.dupe(u8, entry.name);
                const owned_command = allocator.dupe(u8, entry.command) catch |err| {
                    allocator.free(owned_name);
                    return err;
                };
                commands.append(allocator, .{
                    .name = owned_name,
                    .command = owned_command,
                }) catch |err| {
                    allocator.free(owned_name);
                    allocator.free(owned_command);
                    return err;
                };
            }

            if (info.primary_build) |value| {
                if (primary_build == null) {
                    primary_build = try allocator.dupe(u8, value);
                }
            }
            if (info.primary_run) |value| {
                if (primary_run == null) {
                    primary_run = try allocator.dupe(u8, value);
                }
            }
            if (info.primary_test) |value| {
                if (primary_test == null) {
                    primary_test = try allocator.dupe(u8, value);
                }
            }
        }

        if (std.mem.eql(u8, current_dir, normalized_root)) break;
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;

        const next = try std.fmt.allocPrint(allocator, "{s}", .{parent});
        allocator.free(current_dir);
        current_dir = next;
    }

    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .primary_build = primary_build,
        .primary_run = primary_run,
        .primary_test = primary_test,
    };
}

fn findBuildFileAlloc(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findBuildFileAllocWithIO(threaded.io(), allocator, dir);
}

fn findBuildFileAllocWithIO(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const build_bazel = try std.fs.path.join(allocator, &.{ dir, "BUILD.bazel" });
    errdefer allocator.free(build_bazel);
    if (project_io.pathExistsWithIO(io, build_bazel)) return build_bazel;
    allocator.free(build_bazel);

    const build = try std.fs.path.join(allocator, &.{ dir, "BUILD" });
    if (project_io.pathExistsWithIO(io, build)) return build;
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
