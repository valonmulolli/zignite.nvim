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
        try stdout.print("BIN\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const quoted = try common.quoteShellArgAlloc(allocator, item.name);
        defer allocator.free(quoted);
        try stdout.print("COMMAND\tcargo-build-{s}\tcargo build --bin {s}\n", .{ item.name, quoted });
        try stdout.print("COMMAND\tcargo-run-{s}\tcargo run --bin {s}\n", .{ item.name, quoted });
        try stdout.print("COMMAND\tcargo-test-{s}\tcargo test --bin {s}\n", .{ item.name, quoted });
    }
    if (primary_bin == null and items.len > 0) {
        primary_bin = items[0].name;
    }
    if (primary_bin) |name| {
        const quoted = try common.quoteShellArgAlloc(allocator, name);
        defer allocator.free(quoted);

        try stdout.print("PRIMARY_BIN\t{s}\n", .{name});
        try stdout.print("PRIMARY_RUN\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("PRIMARY_RELEASE_RUN\tcargo run --release --bin {s}\n", .{quoted});
        try stdout.print("COMMAND\trun\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("COMMAND\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
        try stdout.print("PREFERRED\trun\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("PREFERRED\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
    }
}

pub fn writeGoOutput(stdout: anytype, allocator: std.mem.Allocator, project_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeGoOutputWithIO(threaded.io(), stdout, allocator, project_path, contents, match_path);
}

pub fn writeGoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, project_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const info = try go.parseInfoWithIO(io, allocator, contents, project_path, match_path);
    defer go.freeOwnedInfo(allocator, info);

    if (info.module_name) |name| {
        try stdout.print("MODULE\t{s}\n", .{name});
    }
    if (info.primary_selector) |selector| {
        try stdout.print("PRIMARY_SELECTOR\t{s}\n", .{selector});
    }
    if (info.primary_build) |command| {
        try stdout.print("COMMAND\tgo-build-package\t{s}\n", .{command});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{command});
        try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
    }
    if (info.primary_run) |command| {
        try stdout.print("COMMAND\tgo-run-package\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
    if (info.primary_test) |command| {
        try stdout.print("COMMAND\tgo-test-package\t{s}\n", .{command});
        try stdout.print("COMMAND\ttest\t{s}\n", .{command});
        try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
    }
}
