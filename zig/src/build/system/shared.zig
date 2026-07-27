const std = @import("std");
const pathing = @import("../../pathing.zig");
const types = @import("types.zig");

pub fn freeOwnedCommands(allocator: std.mem.Allocator, commands: []const types.CommandEntry) void {
    for (commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    if (commands.len > 0) allocator.free(commands);
}

pub fn deinitCommandList(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.CommandEntry),
) void {
    for (commands.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    commands.deinit(allocator);
}

pub fn appendOwnedCommand(
    commands: *std.ArrayList(types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []u8,
) !void {
    errdefer allocator.free(command);

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    try commands.append(allocator, .{ .name = owned_name, .command = command });
}

pub fn appendDupedCommand(
    commands: *std.ArrayList(types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    source_command: []const u8,
) !void {
    const command = try allocator.dupe(u8, source_command);
    try appendOwnedCommand(commands, allocator, name, command);
}

pub fn appendOwnedCommandWithAliases(
    commands: *std.ArrayList(types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []u8,
    aliases: []const []const u8,
) !void {
    try appendOwnedCommand(commands, allocator, name, command);
    for (aliases) |alias| {
        try appendDupedCommand(commands, allocator, alias, command);
    }
}

pub fn nameListContains(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

pub fn pathExists(path: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return pathExistsWithIO(threaded.io(), path);
}

pub fn pathExistsWithIO(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn pathHasFile(root: []const u8, name: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return pathHasFileWithIO(threaded.io(), root, name);
}

pub fn pathHasFileWithIO(io: std.Io, root: []const u8, name: []const u8) bool {
    const full_path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(full_path);

    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
}

pub fn pathHasAnyMarkerWithIO(io: std.Io, root: []const u8, markers: []const []const u8) bool {
    for (markers) |marker| {
        if (pathHasFileWithIO(io, root, marker)) return true;
    }
    return false;
}

pub fn resolveBaseRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) ![]u8 {
    if (project_root) |root| {
        if (root.len > 0) return allocator.dupe(u8, root);
    }
    return allocator.dupe(u8, pathing.dirOrDot(path));
}

pub fn findRootForFilesAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    markers: []const []const u8,
    max_up: usize,
) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findRootForFilesWithinAllocWithIO(threaded.io(), allocator, start_path, markers, null, max_up);
}

pub fn findRootForFilesAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    markers: []const []const u8,
    max_up: usize,
) !?[]u8 {
    return findRootForFilesWithinAllocWithIO(io, allocator, start_path, markers, null, max_up);
}

pub fn makeResult(
    allocator: std.mem.Allocator,
    root: []const u8,
    system: []const u8,
    build_ready: ?bool,
    commands: []types.CommandEntry,
) !types.Result {
    errdefer freeOwnedCommands(allocator, commands);

    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);

    return .{
        .root = owned_root,
        .system = system,
        .build_ready = build_ready,
        .commands = commands,
    };
}

pub fn detectWithMarkers(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
    markers: []const []const u8,
    build_fn: anytype,
) !types.Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectWithMarkersWithIO(threaded.io(), allocator, path, project_root, markers, build_fn);
}

pub fn detectWithMarkersWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
    markers: []const []const u8,
    build_fn: anytype,
) !types.Result {
    if (project_root) |root| {
        if (root.len > 0 and pathHasAnyMarkerWithIO(io, root, markers)) {
            return try build_fn(allocator, root);
        }
        if (root.len > 0) {
            if (try findRootForFilesWithinAllocWithIO(io, allocator, path, markers, root, 12)) |bounded_root| {
                defer allocator.free(bounded_root);
                return try build_fn(allocator, bounded_root);
            }
            return .{};
        }
    }

    if (try findRootForFilesAllocWithIO(io, allocator, path, markers, 12)) |root| {
        defer allocator.free(root);
        return try build_fn(allocator, root);
    }

    return .{};
}

pub fn detectWithMarkersAndBuildWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
    markers: []const []const u8,
    build_fn: anytype,
) !types.Result {
    if (project_root) |root| {
        if (root.len > 0 and pathHasAnyMarkerWithIO(io, root, markers)) {
            return try build_fn(io, allocator, root);
        }
        if (root.len > 0) {
            if (try findRootForFilesWithinAllocWithIO(io, allocator, path, markers, root, 12)) |bounded_root| {
                defer allocator.free(bounded_root);
                return try build_fn(io, allocator, bounded_root);
            }
            return .{};
        }
    }

    if (try findRootForFilesAllocWithIO(io, allocator, path, markers, 12)) |root| {
        defer allocator.free(root);
        return try build_fn(io, allocator, root);
    }

    return .{};
}

pub fn replaceDeeperOwnedRoot(
    allocator: std.mem.Allocator,
    best_root: *?[]u8,
    candidate_root: []u8,
) bool {
    if (best_root.*) |current| {
        if (candidate_root.len > current.len) {
            allocator.free(current);
            best_root.* = candidate_root;
            return true;
        }
        allocator.free(candidate_root);
        return false;
    }

    best_root.* = candidate_root;
    return true;
}

fn hasMarker(io: std.Io, allocator: std.mem.Allocator, markers: []const []const u8, dir: []const u8) !bool {
    _ = allocator;
    return pathHasAnyMarkerWithIO(io, dir, markers);
}

pub fn findRootForFilesWithinAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    markers: []const []const u8,
    boundary: ?[]const u8,
    max_up: usize,
) !?[]u8 {
    return pathing.walkUpwardsAllocWithIO(io, allocator, start_path, max_up, boundary, markers, hasMarker);
}

test "detectWithMarkers uses project root before upward scan" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/package.json", .data = "{}" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "nested", "main.ts" });
    defer allocator.free(filepath);

    const result = try detectWithMarkers(allocator, filepath, root, &.{"package.json"}, testBuildNodeResult);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("node", result.system.?);
}

test "detectWithMarkers does not escape explicit project root boundary" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/apps/app/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/package.json", .data = "{}" });

    const repo_root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", allocator);
    defer allocator.free(repo_root);
    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo/apps/app", allocator);
    defer allocator.free(app_root);
    const filepath = try std.fs.path.join(allocator, &.{ app_root, "src", "main.ts" });
    defer allocator.free(filepath);

    const result = try detectWithMarkers(allocator, filepath, app_root, &.{"package.json"}, testBuildNodeResult);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expect(result.root == null);
    try std.testing.expect(result.system == null);
    try std.testing.expectEqual(@as(usize, 0), result.commands.len);
}

test "resolveBaseRoot uses dot for bare relative path" {
    const allocator = std.testing.allocator;

    const root = try resolveBaseRoot(allocator, "main.ts", null);
    defer allocator.free(root);

    try std.testing.expectEqualStrings(".", root);
}

test "findRootForFilesAlloc walks parents from relative path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/package.json", .data = "{}" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/nested/main.ts", .{repo_relative});
    defer allocator.free(filepath_relative);

    const root = try findRootForFilesAlloc(allocator, filepath_relative, &.{"package.json"}, 12);
    defer if (root) |value| allocator.free(value);

    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings(repo_relative, root.?);
}

fn testBuildNodeResult(allocator: std.mem.Allocator, root: []const u8) !types.Result {
    const commands = try allocator.alloc(types.CommandEntry, 1);

    const owned_name = allocator.dupe(u8, "build") catch |err| {
        allocator.free(commands);
        return err;
    };
    const owned_command = allocator.dupe(u8, "npm run build") catch |err| {
        allocator.free(owned_name);
        allocator.free(commands);
        return err;
    };
    commands[0] = .{
        .name = owned_name,
        .command = owned_command,
    };

    return makeResult(allocator, root, "node", null, commands);
}

test "replaceDeeperOwnedRoot keeps deepest path" {
    const allocator = std.testing.allocator;

    var best_root: ?[]u8 = try allocator.dupe(u8, "/tmp/repo");
    defer if (best_root) |root| allocator.free(root);

    const shallower = try allocator.dupe(u8, "/tmp");
    _ = replaceDeeperOwnedRoot(allocator, &best_root, shallower);
    try std.testing.expectEqualStrings("/tmp/repo", best_root.?);

    const deeper = try allocator.dupe(u8, "/tmp/repo/apps/frontend");
    _ = replaceDeeperOwnedRoot(allocator, &best_root, deeper);
    try std.testing.expectEqualStrings("/tmp/repo/apps/frontend", best_root.?);
}
