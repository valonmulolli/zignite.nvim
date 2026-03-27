const std = @import("std");
const frame = @import("protocol/frame.zig");
const store = @import("config/store.zig");

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

    var json_lines: std.ArrayList([]u8) = .empty;
    defer {
        for (json_lines.items) |line| allocator.free(line);
        json_lines.deinit(allocator);
    }

    const CollectJsonLine = struct {
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]u8),

        fn onLine(self: @This(), line: []const u8) !void {
            const value = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            try self.lines.append(self.allocator, try self.allocator.dupe(u8, value));
        }
    };
    const collect = CollectJsonLine{
        .allocator = allocator,
        .lines = &json_lines,
    };

    const completed = try frame.readUntilEnd(
        allocator,
        reader,
        CONFIG_DAEMON_MAX_LINE,
        CONFIG_DAEMON_REQ_END,
        header.request_id,
        collect.onLine,
    );
    if (!completed) return error.UnexpectedEof;

    var json_buffer: std.ArrayList(u8) = .empty;
    defer json_buffer.deinit(allocator);
    for (json_lines.items) |line| {
        try json_buffer.appendSlice(allocator, line);
    }

    try store.setSyncedConfigJson(json_buffer.items, header.revision);

    try stdout.print("{s} {d}\n", .{ CONFIG_DAEMON_RES_BEGIN, header.request_id });
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

const TestReader = struct {
    lines: []const []const u8,
    index: usize = 0,

    fn readUntilDelimiterOrEofAlloc(
        self: *TestReader,
        allocator: std.mem.Allocator,
        delimiter: u8,
        max_line: usize,
    ) !?[]u8 {
        _ = delimiter;
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        if (line.len > max_line) return error.StreamTooLong;
        return try allocator.dupe(u8, line);
    }
};

test "handleDaemonFrame stores synced config and acknowledges revision" {
    const allocator = std.testing.allocator;
    defer store.reset();

    var reader = TestReader{ .lines = &.{
        "\t{\"build_commands\":{\"zig\":{\"build\":\"zig build\"}}}",
        "@@ZCFG_REQ_END 3",
    } };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try handleDaemonFrame(
        allocator,
        &reader,
        out.writer(allocator),
        "@@ZCFG_REQ_BEGIN 3 19",
    );

    try std.testing.expectEqualStrings(
        "@@ZCFG_RES_BEGIN 3\nREVISION\t19\n@@ZCFG_RES_END 3\n",
        out.items,
    );
    try std.testing.expectEqual(@as(u64, 19), getSyncedRevision());
    try std.testing.expectEqualStrings(
        "{\"build_commands\":{\"zig\":{\"build\":\"zig build\"}}}",
        getSyncedConfigJson().?,
    );
}

test "handleDaemonFrame writes config error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    defer store.reset();

    var reader = TestReader{ .lines = &.{} };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try handleDaemonFrame(
        allocator,
        &reader,
        out.writer(allocator),
        "@@ZCFG_REQ_BEGIN 7 nope",
    );

    try std.testing.expectEqualStrings(
        "@@ZCFG_RES_BEGIN 7\n@@ZCFG_RES_ERR 7 InvalidCharacter\n@@ZCFG_RES_END 7\n",
        out.items,
    );
}
