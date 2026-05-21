const std = @import("std");
const common = @import("../common.zig");
const package_json = @import("../../project/package_json/api.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
pub const markers = &.{ "package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock" };

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
    return try shared.detectWithMarkersAndBuildWithIO(io, allocator, path, project_root, markers, buildResultWithIO);
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildResultWithIO(threaded.io(), allocator, root);
}

fn buildResultWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Result {
    const commands = try buildCommandsAllocWithIO(io, allocator, root);
    return try shared.makeResult(allocator, root, "node", null, commands);
}

fn buildCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildCommandsAllocWithIO(threaded.io(), allocator, root);
}

fn buildCommandsAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    const package_json_path = try std.fs.path.join(allocator, &.{ root, "package.json" });
    defer allocator.free(package_json_path);
    const contents = if (shared.pathExistsWithIO(io, package_json_path))
        try common.readFileAllocWithIO(io, allocator, package_json_path)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(contents);

    const manager = try package_json.detectPackageManagerWithIO(io, allocator, root, contents);
    const install_command = try package_json.formatInstallCommandAlloc(allocator, manager);
    try shared.appendOwnedCommand(&commands, allocator, "install", install_command);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    try package_json.parseScriptsLenient(allocator, contents, &names);

    const preferred = [_][]const u8{ "start", "dev", "build", "test" };
    for (preferred) |name| {
        if (!shared.nameListContains(names.items, name)) continue;
        try shared.appendOwnedCommand(&commands, allocator, name, try package_json.formatScriptCommandAlloc(allocator, manager, name));
    }

    for (names.items) |name| {
        if (std.mem.eql(u8, name, "install")) continue;

        var already_added = false;
        for (preferred) |preferred_name| {
            if (std.mem.eql(u8, name, preferred_name)) {
                already_added = true;
                break;
            }
        }
        if (already_added) continue;

        try shared.appendOwnedCommand(&commands, allocator, name, try package_json.formatScriptCommandAlloc(allocator, manager, name));
    }

    return try commands.toOwnedSlice(allocator);
}

test "detect tolerates malformed package json and keeps install command" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package.json", .data = "{ invalid json" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    const result = try detect(allocator, filepath, root);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("node", result.system.?);
    try std.testing.expectEqual(@as(usize, 1), result.commands.len);
    try std.testing.expectEqualStrings("install", result.commands[0].name);
    try std.testing.expectEqualStrings("npm install", result.commands[0].command);
}

test "detect exposes custom package scripts beyond default four names" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package.json", .data =
        \\{"scripts":{"lint":"eslint .","typecheck":"tsc --noEmit","start":"vite"}}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    const result = try detect(allocator, filepath, root);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("install", result.commands[0].name);
    try std.testing.expectEqualStrings("start", result.commands[1].name);
    try std.testing.expectEqualStrings("lint", result.commands[2].name);
    try std.testing.expectEqualStrings("npm run lint", result.commands[2].command);
    try std.testing.expectEqualStrings("typecheck", result.commands[3].name);
    try std.testing.expectEqualStrings("npm run typecheck", result.commands[3].command);
}
