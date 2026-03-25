const std = @import("std");
const common = @import("../common.zig");
const package_json = @import("../../project/package_json/api.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
const markers = &.{ "package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock" };

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0 and shared.rootHasAnyMarker(root, markers)) {
            return try buildResult(allocator, root);
        }
    }

    if (try shared.findRootForFilesAlloc(allocator, path, markers, 12)) |root| {
        defer allocator.free(root);
        return try buildResult(allocator, root);
    }

    return .{};
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildCommandsAlloc(allocator, root);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "node", .commands = commands };
}

fn buildCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const package_json_path = try std.fs.path.join(allocator, &.{ root, "package.json" });
    defer allocator.free(package_json_path);
    const contents = if (shared.pathExists(package_json_path))
        try common.readFileAlloc(allocator, package_json_path)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(contents);

    const manager = try package_json.detectPackageManager(allocator, root, contents);
    const start_command = try package_json.formatScriptCommandAlloc(allocator, manager, "start");
    const dev_command = try package_json.formatScriptCommandAlloc(allocator, manager, "dev");
    const build_command = try package_json.formatScriptCommandAlloc(allocator, manager, "build");
    const test_command = try package_json.formatScriptCommandAlloc(allocator, manager, "test");
    const install_command = try package_json.formatInstallCommandAlloc(allocator, manager);

    try shared.appendOwnedCommand(&commands, allocator, "start", start_command);
    try shared.appendOwnedCommand(&commands, allocator, "dev", dev_command);
    try shared.appendOwnedCommand(&commands, allocator, "build", build_command);
    try shared.appendOwnedCommand(&commands, allocator, "test", test_command);
    try shared.appendOwnedCommand(&commands, allocator, "install", install_command);

    return try commands.toOwnedSlice(allocator);
}
