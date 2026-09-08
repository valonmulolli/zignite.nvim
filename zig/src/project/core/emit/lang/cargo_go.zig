const std = @import("std");
const cargo = @import("../../../cargo/api.zig");
const common = @import("../../common.zig");
const go = @import("../../../go/api.zig");

pub fn writeCargoOutput(stdout: anytype, allocator: std.mem.Allocator, cargo_toml_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const items = try cargo.parseTargets(allocator, contents, cargo_toml_path, match_path);
    defer cargo.freeOwnedTargets(allocator, items);
    var primary_bin: ?[]const u8 = null;
    for (items) |item| {
        if (item.matched and primary_bin == null) {
            primary_bin = item.name;
        }
        if (!common.hasInvalidPayloadChars(item.name)) {
            try stdout.print("BIN\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        }
        const quoted = try common.quoteShellArgAlloc(allocator, item.name);
        defer allocator.free(quoted);
        const build_name = try std.fmt.allocPrint(allocator, "cargo-build-{s}", .{item.name});
        defer allocator.free(build_name);
        const run_name = try std.fmt.allocPrint(allocator, "cargo-run-{s}", .{item.name});
        defer allocator.free(run_name);
        const test_name = try std.fmt.allocPrint(allocator, "cargo-test-{s}", .{item.name});
        defer allocator.free(test_name);
        const build_command = try std.fmt.allocPrint(allocator, "cargo build --bin {s}", .{quoted});
        defer allocator.free(build_command);
        const run_command = try std.fmt.allocPrint(allocator, "cargo run --bin {s}", .{quoted});
        defer allocator.free(run_command);
        const test_command = try std.fmt.allocPrint(allocator, "cargo test --bin {s}", .{quoted});
        defer allocator.free(test_command);
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ build_name, build_command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ run_name, run_command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ test_name, test_command });
    }
    if (primary_bin == null and items.len > 0) {
        primary_bin = items[0].name;
    }
    if (primary_bin) |name| {
        const quoted = try common.quoteShellArgAlloc(allocator, name);
        defer allocator.free(quoted);

        try common.writeSafeStringRecord(stdout, "PRIMARY_BIN", .{name});
        const run_command = try std.fmt.allocPrint(allocator, "cargo run --bin {s}", .{quoted});
        defer allocator.free(run_command);
        const release_run_command = try std.fmt.allocPrint(allocator, "cargo run --release --bin {s}", .{quoted});
        defer allocator.free(release_run_command);
        try common.writeSafeStringRecord(stdout, "PRIMARY_RUN", .{run_command});
        try common.writeSafeStringRecord(stdout, "PRIMARY_RELEASE_RUN", .{release_run_command});
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "run", run_command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "release-run", release_run_command });
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "run", run_command });
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "release-run", release_run_command });
    }
}

pub fn writeGoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, project_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const info = try go.parseInfoWithIO(io, allocator, contents, project_path, match_path);
    defer go.freeOwnedInfo(allocator, info);

    if (info.module_name) |name| {
        try common.writeSafeStringRecord(stdout, "MODULE", .{name});
    }
    if (info.primary_selector) |selector| {
        try common.writeSafeStringRecord(stdout, "PRIMARY_SELECTOR", .{selector});
    }
    if (info.primary_build) |command| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "go-build-package", command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "build", command });
        try common.writeSafeStringRecord(stdout, "PRIMARY_BUILD", .{command});
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "build", command });
    }
    if (info.primary_run) |command| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "go-run-package", command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "run", command });
        try common.writeSafeStringRecord(stdout, "PRIMARY_RUN", .{command});
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "run", command });
    }
    if (info.primary_test) |command| {
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "go-test-package", command });
        try common.writeSafeStringRecord(stdout, "COMMAND", .{ "test", command });
        try common.writeSafeStringRecord(stdout, "PRIMARY_TEST", .{command});
        try common.writeSafeStringRecord(stdout, "PREFERRED", .{ "test", command });
    }
}
