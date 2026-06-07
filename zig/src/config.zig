const std = @import("std");
const frame = @import("protocol/frame.zig");
const protocol_stdio = @import("protocol/stdio.zig");
const store = @import("config/store.zig");
const validate = @import("config/validate.zig");

pub const CONFIG_DAEMON_REQ_BEGIN = "@@ZCFG_REQ_BEGIN";
pub const CONFIG_DAEMON_REQ_END = "@@ZCFG_REQ_END";
pub const CONFIG_DAEMON_RES_BEGIN = "@@ZCFG_RES_BEGIN";
pub const CONFIG_DAEMON_RES_END = "@@ZCFG_RES_END";
pub const CONFIG_DAEMON_RES_ERR = "@@ZCFG_RES_ERR";
const CONFIG_DAEMON_MAX_LINE = 65536;

const ConfigDaemonRequestHeader = struct {
    request_id: u64,
    revision: u64,
};

pub const Options = struct {
    revision: u64,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var revision: ?u64 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--config-sync")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--revision=")) {
            revision = try std.fmt.parseInt(u64, arg["--revision=".len..], 10);
            continue;
        }
        return error.InvalidConfigSyncFlag;
    }

    return .{
        .revision = revision orelse return error.MissingConfigSyncRevision,
    };
}

pub fn runMode(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var stdin_buffer: [protocol_stdio.buffer_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const json_payload = try stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(json_payload);

    const warnings = try validate.collectWarnings(allocator, json_payload);
    defer validate.freeWarnings(allocator, warnings);

    try store.setSyncedConfigJson(json_payload, options.revision);

    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();
    try writeWarnings(stdout, warnings);
    try stdout.print("REVISION\t{d}\n", .{options.revision});
    try stdout.flush();
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = parseConfigDaemonBegin(begin_line) catch |err| {
        if (frame.parseRequestId(begin_line, CONFIG_DAEMON_REQ_BEGIN)) |request_id| {
            try frame.writeErrorResponse(
                stdout,
                CONFIG_DAEMON_RES_BEGIN,
                CONFIG_DAEMON_RES_ERR,
                CONFIG_DAEMON_RES_END,
                request_id,
                @errorName(err),
            );
            try stdout.flush();
            return;
        }
        return err;
    };

    const json_lines = try frame.collectOwnedLinesUntilEnd(
        allocator,
        reader,
        CONFIG_DAEMON_MAX_LINE,
        CONFIG_DAEMON_REQ_END,
        header.request_id,
        .{
            .strip_leading_tab = true,
            .skip_empty = false,
            .max_bytes = 16 * 1024 * 1024,
        },
    );
    defer {
        for (json_lines) |line| allocator.free(line);
        allocator.free(json_lines);
    }

    var json_buffer: std.ArrayList(u8) = .empty;
    defer json_buffer.deinit(allocator);
    for (json_lines) |line| {
        try json_buffer.appendSlice(allocator, line);
    }

    const warnings = try validate.collectWarnings(allocator, json_buffer.items);
    defer validate.freeWarnings(allocator, warnings);

    try store.setSyncedConfigJson(json_buffer.items, header.revision);

    try stdout.print("{s} {d}\n", .{ CONFIG_DAEMON_RES_BEGIN, header.request_id });
    try writeWarnings(stdout, warnings);
    try stdout.print("REVISION\t{d}\n", .{header.revision});
    try stdout.print("{s} {d}\n", .{ CONFIG_DAEMON_RES_END, header.request_id });
    try stdout.flush();
}

pub fn getSyncedConfigJson() ?[]const u8 {
    return store.getSyncedConfigJson();
}

pub fn getSyncedRevision() u64 {
    return store.getSyncedRevision();
}

fn writeWarnings(stdout: anytype, warnings: [][]u8) !void {
    for (warnings) |warning| {
        try stdout.print("WARN\t{s}\n", .{warning});
    }
}

fn parseConfigDaemonBegin(line: []const u8) !ConfigDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidConfigDaemonHeader;
    if (!std.mem.eql(u8, marker, CONFIG_DAEMON_REQ_BEGIN)) {
        return error.InvalidConfigDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidConfigDaemonHeader, 10);
    const revision = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidConfigDaemonHeader, 10);
    if (it.next() != null) {
        return error.InvalidConfigDaemonHeader;
    }

    return .{
        .request_id = request_id,
        .revision = revision,
    };
}

const TestReader = frame.TestReader;

test "handleDaemonFrame stores synced config and acknowledges revision" {
    const allocator = std.testing.allocator;
    defer store.reset();

    var reader = TestReader{ .lines = &.{
        "\t{\"build_commands\":{\"zig\":{\"build\":\"zig build\"}}}",
        "@@ZCFG_REQ_END 3",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDaemonFrame(
        allocator,
        &reader,
        &out.writer,
        "@@ZCFG_REQ_BEGIN 3 19",
    );

    try std.testing.expectEqualStrings(
        "@@ZCFG_RES_BEGIN 3\nREVISION\t19\n@@ZCFG_RES_END 3\n",
        out.written(),
    );
    try std.testing.expectEqual(@as(u64, 19), getSyncedRevision());
    try std.testing.expectEqualStrings(
        "{\"build_commands\":{\"zig\":{\"build\":\"zig build\"}}}",
        getSyncedConfigJson().?,
    );
}

test "handleDaemonFrame includes backend config warnings before revision" {
    const allocator = std.testing.allocator;
    defer store.reset();

    var reader = TestReader{ .lines = &.{
        "\t{\"detect\":{\"zig\":\"yes\"},\"timeout\":\"slow\"}",
        "@@ZCFG_REQ_END 5",
    } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDaemonFrame(
        allocator,
        &reader,
        &out.writer,
        "@@ZCFG_REQ_BEGIN 5 23",
    );

    try std.testing.expect(std.mem.find(u8, out.written(), "@@ZCFG_RES_BEGIN 5\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "WARN\tInvalid config detect.zig: expected boolean, got string\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "WARN\tInvalid config timeout: expected positive number or null, got string\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "REVISION\t23\n") != null);
}

test "handleDaemonFrame writes config error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    defer store.reset();

    var reader = TestReader{ .lines = &.{} };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDaemonFrame(
        allocator,
        &reader,
        &out.writer,
        "@@ZCFG_REQ_BEGIN 7 nope",
    );

    try std.testing.expectEqualStrings(
        "@@ZCFG_RES_BEGIN 7\n@@ZCFG_RES_ERR 7 InvalidCharacter\n@@ZCFG_RES_END 7\n",
        out.written(),
    );
}

test "parseArgs accepts one-shot config sync flags" {
    const options = try parseArgs(&.{
        "--config-sync",
        "--revision=42",
    });

    try std.testing.expectEqual(@as(u64, 42), options.revision);
}
