const std = @import("std");
const bazel = @import("../../../bazel/api.zig");
const common = @import("../../common.zig");
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
        var safe = !common.hasInvalidPayloadChars(item.rule_name) and !common.hasInvalidPayloadChars(item.name);
        for (item.source_entries) |entry| {
            safe = safe and !common.hasInvalidPayloadChars(entry);
        }
        if (safe) {
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
    }

    try writeBazelCommandInfo(stdout, info);
}

pub fn writeBazelWorkspaceOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    const info = try bazel.buildWorkspaceCommandInfoWithIO(io, allocator, options.path, options.match_path);
    defer bazel.freeOwnedCommandInfo(allocator, info);
    try writeBazelCommandInfo(stdout, info);
}

fn writeBazelCommandInfo(stdout: anytype, info: bazel.CommandInfo) !void {
    for (info.commands) |entry| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ entry.name, entry.command });
    }
    try stdout.print("COMMAND\tbazel-query\tbazel query $zignite_args\n", .{});
    try stdout.print("COMMAND\tbazel-clean\tbazel clean\n", .{});
    try stdout.print("COMMAND\tbazel-build-all\tbazel build //...\n", .{});
    try stdout.print("COMMAND\tbazel-test-all\tbazel test //...\n", .{});
    if (info.primary_build) |command| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "bazel-build", command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "build", command });
        try common.writeSafeStringRecord(stdout, "PRIMARY_BUILD", .{command});
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "build", command });
    }
    if (info.primary_run) |command| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "bazel-run", command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "run", command });
        try common.writeSafeStringRecord(stdout, "PRIMARY_RUN", .{command});
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "run", command });
    }
    if (info.primary_test) |command| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "bazel-test", command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "test", command });
        try common.writeSafeStringRecord(stdout, "PRIMARY_TEST", .{command});
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "test", command });
    }
}
