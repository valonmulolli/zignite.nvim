const std = @import("std");
const bazel = @import("../../../bazel/api.zig");
const types = @import("../../types.zig");

const Options = types.Options;

pub fn writeBazelProjectOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    const items = try bazel.parseTargets(allocator, contents);
    defer bazel.freeOwnedTargets(allocator, items);
    const info = try bazel.buildCommandInfo(
        allocator,
        items,
        options.path,
        options.package_path,
        options.match_path,
    );
    defer bazel.freeOwnedCommandInfo(allocator, info);

    for (items) |item| {
        try stdout.print("TARGET\t{s}\t{s}\t{d}\t{d}", .{
            item.rule_name,
            item.name,
            if (item.supports_run) @as(u8, 1) else @as(u8, 0),
            if (item.supports_test) @as(u8, 1) else @as(u8, 0),
        });
        for (item.source_entries) |entry| {
            try stdout.print("\t{s}", .{entry});
        }
        try stdout.writeByte('\n');
    }

    try writeBazelCommandInfo(stdout, info);
}

pub fn writeBazelWorkspaceOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeBazelWorkspaceOutputWithIO(threaded.io(), stdout, allocator, options);
}

pub fn writeBazelWorkspaceOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    const info = try bazel.buildWorkspaceCommandInfoWithIO(io, allocator, options.path, options.match_path);
    defer bazel.freeOwnedCommandInfo(allocator, info);
    try writeBazelCommandInfo(stdout, info);
}

fn writeBazelCommandInfo(stdout: anytype, info: bazel.CommandInfo) !void {
    for (info.commands) |entry| {
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
    try stdout.print("COMMAND\tbazel-query\tbazel query $zignite_args\n", .{});
    try stdout.print("COMMAND\tbazel-clean\tbazel clean\n", .{});
    try stdout.print("COMMAND\tbazel-build-all\tbazel build //...\n", .{});
    try stdout.print("COMMAND\tbazel-test-all\tbazel test //...\n", .{});
    if (info.primary_build) |command| {
        try stdout.print("COMMAND\tbazel-build\t{s}\n", .{command});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{command});
        try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
    }
    if (info.primary_run) |command| {
        try stdout.print("COMMAND\tbazel-run\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
    if (info.primary_test) |command| {
        try stdout.print("COMMAND\tbazel-test\t{s}\n", .{command});
        try stdout.print("COMMAND\ttest\t{s}\n", .{command});
        try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
    }
}
