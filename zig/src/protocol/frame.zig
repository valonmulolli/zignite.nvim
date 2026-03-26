const std = @import("std");

pub fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

pub fn isFrameEndLine(line: []const u8, marker_name: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, marker_name)) return false;
    const raw_id = it.next() orelse return false;
    if (it.next() != null) return false;
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

pub fn parseRequestId(line: []const u8, begin_marker: []const u8) ?u64 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return null;
    if (!std.mem.eql(u8, marker, begin_marker)) return null;
    const raw_id = it.next() orelse return null;
    return std.fmt.parseInt(u64, raw_id, 10) catch null;
}

pub fn writeErrorResponse(
    writer: anytype,
    response_begin: []const u8,
    response_err: []const u8,
    response_end: []const u8,
    request_id: u64,
    message: []const u8,
) !void {
    try writer.print("{s} {d}\n", .{ response_begin, request_id });
    try writer.print("{s} {d} {s}\n", .{ response_err, request_id, message });
    try writer.print("{s} {d}\n", .{ response_end, request_id });
}

pub fn readUntilEnd(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_line: usize,
    end_marker: []const u8,
    request_id: u64,
    on_line: anytype,
) !bool {
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_line);
        if (maybe_line == null) return false;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = stripTrailingCR(line_owned);

        if (isFrameEndLine(line, end_marker, request_id)) return true;
        try on_line(line);
    }
}

pub fn skipUntilEnd(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_line: usize,
    end_marker: []const u8,
    request_id: u64,
) !bool {
    const Skip = struct {
        fn onLine(_: []const u8) !void {}
    };
    return readUntilEnd(allocator, reader, max_line, end_marker, request_id, Skip.onLine);
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

test "stripTrailingCR trims only trailing carriage return" {
    try std.testing.expectEqualStrings("line", stripTrailingCR("line\r"));
    try std.testing.expectEqualStrings("line", stripTrailingCR("line"));
}

test "isFrameEndLine validates marker and request id" {
    try std.testing.expect(isFrameEndLine("@@ZPRJ_REQ_END 19", "@@ZPRJ_REQ_END", 19));
    try std.testing.expect(!isFrameEndLine("@@ZPRJ_REQ_END 18", "@@ZPRJ_REQ_END", 19));
    try std.testing.expect(!isFrameEndLine("@@ZDET_REQ_END 19", "@@ZPRJ_REQ_END", 19));
    try std.testing.expect(!isFrameEndLine("@@ZPRJ_REQ_END 19 extra", "@@ZPRJ_REQ_END", 19));
}

test "parseRequestId extracts request id from begin frame" {
    try std.testing.expectEqual(@as(?u64, 42), parseRequestId("@@ZQF_BEGIN 42 100 2048 1 50 0", "@@ZQF_BEGIN"));
    try std.testing.expectEqual(@as(?u64, null), parseRequestId("@@ZQF_BEGIN nope 100", "@@ZQF_BEGIN"));
    try std.testing.expectEqual(@as(?u64, null), parseRequestId("@@ZDET_REQ_BEGIN 42 cargo", "@@ZQF_BEGIN"));
}

test "writeErrorResponse emits protocol frame" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeErrorResponse(
        out.writer(allocator),
        "@@ZDET_RES_BEGIN",
        "@@ZDET_RES_ERR",
        "@@ZDET_RES_END",
        7,
        "InvalidDetectTool",
    );

    try std.testing.expectEqualStrings(
        "@@ZDET_RES_BEGIN 7\n@@ZDET_RES_ERR 7 InvalidDetectTool\n@@ZDET_RES_END 7\n",
        out.items,
    );
}

test "readUntilEnd forwards lines until matching frame end" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "first\r",
        "@@ZPRJ_REQ_END 6",
        "second",
        "@@ZPRJ_REQ_END 7\r",
        "tail",
    } };
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(allocator);
    var writer = collected.writer(allocator);
    const Collect = struct {
        writer: *@TypeOf(collected.writer(allocator)),

        fn onLine(self: @This(), line: []const u8) !void {
            try self.writer.writeAll(line);
            try self.writer.writeByte('\n');
        }
    };
    const collect = Collect{ .writer = &writer };

    const completed = try readUntilEnd(
        allocator,
        &reader,
        64,
        "@@ZPRJ_REQ_END",
        7,
        collect.onLine,
    );

    try std.testing.expect(completed);
    try std.testing.expectEqualStrings("first\n@@ZPRJ_REQ_END 6\nsecond\n", collected.items);
    try std.testing.expectEqual(@as(usize, 4), reader.index);
}

test "skipUntilEnd returns false on eof before matching end" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{ "line-one", "line-two" } };

    const completed = try skipUntilEnd(
        allocator,
        &reader,
        64,
        "@@ZPRJ_REQ_END",
        7,
    );

    try std.testing.expect(!completed);
    try std.testing.expectEqual(@as(usize, 2), reader.index);
}

test "readUntilEnd propagates oversized line errors" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{ "123456" } };
    const Noop = struct {
        fn onLine(_: []const u8) !void {}
    };

    try std.testing.expectError(
        error.StreamTooLong,
        readUntilEnd(allocator, &reader, 3, "@@ZPRJ_REQ_END", 1, Noop.onLine),
    );
}
