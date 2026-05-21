const std = @import("std");

pub const Query = enum {
    c_family,
    bazel_root,
    jvm_root,
    node_root,
    python_root,
};

pub const CommandEntry = struct {
    name: []const u8,
    command: []u8,
};

pub const Result = struct {
    root: ?[]u8 = null,
    system: ?[]const u8 = null,
    build_ready: ?bool = null,
    commands: []CommandEntry = &.{},
};

pub fn parseQuery(value: []const u8) !Query {
    if (std.ascii.eqlIgnoreCase(value, "c-family")) return .c_family;
    if (std.ascii.eqlIgnoreCase(value, "bazel-root")) return .bazel_root;
    if (std.ascii.eqlIgnoreCase(value, "jvm-root")) return .jvm_root;
    if (std.ascii.eqlIgnoreCase(value, "node-root")) return .node_root;
    if (std.ascii.eqlIgnoreCase(value, "python-root")) return .python_root;
    return error.InvalidSystemQuery;
}

pub fn freeOwnedResult(allocator: std.mem.Allocator, result: Result) void {
    if (result.root) |root| allocator.free(root);
    for (result.commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    if (result.commands.len > 0) {
        allocator.free(result.commands);
    }
}
