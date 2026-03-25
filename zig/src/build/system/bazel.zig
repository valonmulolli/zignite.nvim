const std = @import("std");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0 and shared.rootHasAnyMarker(root, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" })) {
            return try buildResult(allocator, root);
        }
    }

    if (try shared.findRootForFilesAlloc(allocator, path, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }, 12)) |root| {
        defer allocator.free(root);
        return try buildResult(allocator, root);
    }

    return .{};
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildCommandsAlloc(allocator);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "bazel", .commands = commands };
}

fn buildCommandsAlloc(allocator: std.mem.Allocator) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const query_command = try allocator.dupe(u8, "bazel query $zignite_args");
    const clean_command = try allocator.dupe(u8, "bazel clean");
    const build_command = try allocator.dupe(u8, "bazel build //...");
    const test_command = try allocator.dupe(u8, "bazel test //...");

    try shared.appendOwnedCommand(&commands, allocator, "bazel-query", query_command);
    try shared.appendOwnedCommand(&commands, allocator, "bazel-clean", clean_command);
    try shared.appendOwnedCommand(&commands, allocator, "bazel-build-all", build_command);
    try shared.appendOwnedCommand(&commands, allocator, "bazel-test-all", test_command);
    try shared.appendDupedCommand(&commands, allocator, "build", build_command);
    try shared.appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
}
