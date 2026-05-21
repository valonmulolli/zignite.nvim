const std = @import("std");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
pub const markers = &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" };

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
    return try shared.detectWithMarkersWithIO(io, allocator, path, project_root, markers, buildResult);
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const commands = try buildCommandsAlloc(allocator);
    return try shared.makeResult(allocator, root, "bazel", null, commands);
}

fn buildCommandsAlloc(allocator: std.mem.Allocator) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    try shared.appendDupedCommand(&commands, allocator, "bazel-query", "bazel query $zignite_args");
    try shared.appendDupedCommand(&commands, allocator, "bazel-clean", "bazel clean");
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "bazel-build-all", try allocator.dupe(u8, "bazel build //..."), &.{"build"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "bazel-test-all", try allocator.dupe(u8, "bazel test //..."), &.{"test"});

    return try commands.toOwnedSlice(allocator);
}
