const std = @import("std");
const common = @import("../common.zig");
const pyproject = @import("../../project/pyproject/api.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
const markers = &.{ "pyproject.toml", "uv.lock" };

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
        if (commands.len > 0) allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "python", .commands = commands };
}

fn buildCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    const pyproject_path = try std.fs.path.join(allocator, &.{ root, "pyproject.toml" });
    defer allocator.free(pyproject_path);

    const has_uv_lock = shared.pathHasFile(root, "uv.lock");
    const uses_uv = blk: {
        if (has_uv_lock) break :blk true;
        if (!shared.pathExists(pyproject_path)) break :blk false;
        const contents = try common.readFileAlloc(allocator, pyproject_path);
        defer allocator.free(contents);
        break :blk pyproject.hasToolSection(contents, "tool.uv");
    };
    if (!uses_uv) return &.{};

    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    try shared.appendOwnedCommand(&commands, allocator, "run", try allocator.dupe(u8, "uv run -m main"));
    try shared.appendOwnedCommand(&commands, allocator, "test", try allocator.dupe(u8, "uv run pytest"));
    try shared.appendOwnedCommand(&commands, allocator, "install", try allocator.dupe(u8, "uv sync"));

    return try commands.toOwnedSlice(allocator);
}
