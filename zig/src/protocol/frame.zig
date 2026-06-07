const std = @import("std");
const common = @import("../project/core/common.zig");

fn readerSupportsMethod(comptime T: type, comptime name: []const u8) bool {
    if (std.meta.hasMethod(T, name)) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| std.meta.hasMethod(pointer.child, name),
        else => false,
    };
}

pub fn readLineAlloc(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_line: usize,
) !?[]u8 {
    if (comptime readerSupportsMethod(@TypeOf(reader), "takeDelimiter")) {
        const maybe_line = try reader.takeDelimiter('\n');
        if (maybe_line == null) return null;
        const line = maybe_line.?;
        if (line.len > max_line) return error.StreamTooLong;
        return try allocator.dupe(u8, line);
    }
    if (comptime readerSupportsMethod(@TypeOf(reader), "readUntilDelimiterOrEofAlloc")) {
        return try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_line);
    }
    @compileError("reader must support takeDelimiter or readUntilDelimiterOrEofAlloc");
}

pub fn stripTrailingCR(line: []const u8) []const u8 {
    return common.stripTrailingCR(line);
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

pub const DispatchErrorFrame = struct {
    response_begin: []const u8,
    response_err: []const u8,
    response_end: []const u8,
};

/// Catches errors from a `handleDaemonFrame` call, writes the protocol error
/// frame using the request id parsed from the begin line, and flushes.
/// Returns `error.UnexpectedEof` unchanged so the daemon can propagate it.
pub fn handleDispatchError(
    err: anyerror,
    writer: anytype,
    begin_line: []const u8,
    begin_marker: []const u8,
    frame: DispatchErrorFrame,
) !void {
    if (err == error.UnexpectedEof) return err;
    if (parseRequestId(begin_line, begin_marker)) |request_id| {
        try writeErrorResponse(
            writer,
            frame.response_begin,
            frame.response_err,
            frame.response_end,
            request_id,
            @errorName(err),
        );
        try writer.flush();
    }
}

pub const BeginFrame = struct {
    request_id: u64,
    it: std.mem.TokenIterator(u8, .scalar),
};

/// Splits a daemon begin line, validates the marker, and parses the request id.
/// Returns the request id and a token iterator over the remaining fields.
/// Callers should consume additional fields via `it.next()` and reject extras
/// by checking that `it.next() == null` once all expected fields are parsed.
pub fn parseBeginFrame(
    line: []const u8,
    begin_marker: []const u8,
    invalid_err: anyerror,
) !BeginFrame {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return invalid_err;
    if (!std.mem.eql(u8, marker, begin_marker)) return invalid_err;
    const request_id = try std.fmt.parseInt(
        u64,
        it.next() orelse return invalid_err,
        10,
    );
    return .{ .request_id = request_id, .it = it };
}

pub fn readUntilEnd(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_line: usize,
    end_marker: []const u8,
    request_id: u64,
    context: anytype,
    on_line: anytype,
) !bool {
    while (true) {
        const maybe_line = try readLineAlloc(allocator, reader, max_line);
        if (maybe_line == null) return false;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = stripTrailingCR(line_owned);

        if (isFrameEndLine(line, end_marker, request_id)) return true;
        try on_line(context, line);
    }
}

pub const CollectLineOptions = struct {
    strip_leading_tab: bool = false,
    skip_empty: bool = false,
    max_bytes: ?usize = null,
};

pub fn collectOwnedLinesUntilEnd(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_line: usize,
    end_marker: []const u8,
    request_id: u64,
    options: CollectLineOptions,
) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var total_bytes: usize = 0;

    const Collect = struct {
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]u8),
        options: CollectLineOptions,
        total_bytes: *usize,

        fn onLine(self: @This(), line: []const u8) !void {
            const value = if (self.options.strip_leading_tab and line.len > 0 and line[0] == '\t')
                line[1..]
            else
                line;
            if (self.options.skip_empty and value.len == 0) return;
            if (self.options.max_bytes) |cap| {
                if (self.lines.items.len > 0 and self.total_bytes.* + value.len + 1 > cap) {
                    return error.StreamTooLong;
                }
                self.total_bytes.* += value.len + 1;
            }
            const owned_value = try self.allocator.dupe(u8, value);
            self.lines.append(self.allocator, owned_value) catch |err| {
                self.allocator.free(owned_value);
                return err;
            };
        }
    };

    const collect = Collect{
        .allocator = allocator,
        .lines = &lines,
        .options = options,
        .total_bytes = &total_bytes,
    };

    const completed = try readUntilEnd(
        allocator,
        reader,
        max_line,
        end_marker,
        request_id,
        collect,
        Collect.onLine,
    );
    if (!completed) return error.UnexpectedEof;

    return try lines.toOwnedSlice(allocator);
}

pub fn skipUntilEnd(
    allocator: std.mem.Allocator,
    reader: anytype,
    max_line: usize,
    end_marker: []const u8,
    request_id: u64,
) !bool {
    const Skip = struct {
        fn onLine(_: void, _: []const u8) !void {}
    };
    return readUntilEnd(allocator, reader, max_line, end_marker, request_id, {}, Skip.onLine);
}

pub const TestReader = struct {
    lines: []const []const u8 = &.{},
    index: usize = 0,
    pub fn readUntilDelimiterOrEofAlloc(
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
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeErrorResponse(
        &out.writer,
        "@@ZDET_RES_BEGIN",
        "@@ZDET_RES_ERR",
        "@@ZDET_RES_END",
        7,
        "InvalidDetectTool",
    );

    try std.testing.expectEqualStrings(
        "@@ZDET_RES_BEGIN 7\n@@ZDET_RES_ERR 7 InvalidDetectTool\n@@ZDET_RES_END 7\n",
        out.written(),
    );
}

test "handleDispatchError writes frame and flushes for parseable request id" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDispatchError(
        error.InvalidProjectDaemonHeader,
        &out.writer,
        "@@ZPRJ_REQ_BEGIN 11 notavalidmarker",
        "@@ZPRJ_REQ_BEGIN",
        .{ .response_begin = "@@ZPRJ_RES_BEGIN", .response_err = "@@ZPRJ_RES_ERR", .response_end = "@@ZPRJ_RES_END" },
    );

    try std.testing.expectEqualStrings(
        "@@ZPRJ_RES_BEGIN 11\n@@ZPRJ_RES_ERR 11 InvalidProjectDaemonHeader\n@@ZPRJ_RES_END 11\n",
        out.written(),
    );
}

test "handleDispatchError silently skips when request id is unparseable" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDispatchError(
        error.InvalidProjectDaemonHeader,
        &out.writer,
        "@@ZPRJ_REQ_BEGIN",
        "@@ZPRJ_REQ_BEGIN",
        .{ .response_begin = "@@ZPRJ_RES_BEGIN", .response_err = "@@ZPRJ_RES_ERR", .response_end = "@@ZPRJ_RES_END" },
    );

    try std.testing.expectEqualStrings("", out.written());
}

test "handleDispatchError propagates UnexpectedEof unchanged" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const result = handleDispatchError(
        error.UnexpectedEof,
        &out.writer,
        "@@ZPRJ_REQ_BEGIN 5 marker",
        "@@ZPRJ_REQ_BEGIN",
        .{ .response_begin = "@@ZPRJ_RES_BEGIN", .response_err = "@@ZPRJ_RES_ERR", .response_end = "@@ZPRJ_RES_END" },
    );
    try std.testing.expectError(error.UnexpectedEof, result);
    try std.testing.expectEqualStrings("", out.written());
}

test "parseBeginFrame extracts request id and returns iterator over remainder" {
    var result = try parseBeginFrame("@@ZBR_REQ_BEGIN 7 --build-resolve --filetype=c", "@@ZBR_REQ_BEGIN", error.InvalidHeader);
    try std.testing.expectEqual(@as(u64, 7), result.request_id);
    try std.testing.expectEqualStrings("--build-resolve", result.it.next().?);
    try std.testing.expectEqualStrings("--filetype=c", result.it.next().?);
    try std.testing.expect(result.it.next() == null);
}

test "parseBeginFrame errors on wrong marker" {
    try std.testing.expectError(error.InvalidHeader, parseBeginFrame("@@ZDET_REQ_BEGIN 5", "@@ZBR_REQ_BEGIN", error.InvalidHeader));
}

test "parseBeginFrame errors on missing request id" {
    try std.testing.expectError(error.InvalidHeader, parseBeginFrame("@@ZBR_REQ_BEGIN", "@@ZBR_REQ_BEGIN", error.InvalidHeader));
}

test "parseBeginFrame errors on non-numeric request id" {
    try std.testing.expectError(error.InvalidCharacter, parseBeginFrame("@@ZBR_REQ_BEGIN abc", "@@ZBR_REQ_BEGIN", error.InvalidHeader));
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
    var collected: std.Io.Writer.Allocating = .init(allocator);
    defer collected.deinit();
    const Collect = struct {
        writer: *std.Io.Writer,

        fn onLine(self: @This(), line: []const u8) !void {
            try self.writer.writeAll(line);
            try self.writer.writeByte('\n');
        }
    };
    const collect = Collect{ .writer = &collected.writer };

    const completed = try readUntilEnd(
        allocator,
        &reader,
        64,
        "@@ZPRJ_REQ_END",
        7,
        collect,
        Collect.onLine,
    );

    try std.testing.expect(completed);
    try std.testing.expectEqualStrings("first\n@@ZPRJ_REQ_END 6\nsecond\n", collected.written());
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
    var reader = TestReader{ .lines = &.{"123456"} };
    const Noop = struct {
        fn onLine(_: void, _: []const u8) !void {}
    };

    try std.testing.expectError(
        error.StreamTooLong,
        readUntilEnd(allocator, &reader, 3, "@@ZPRJ_REQ_END", 1, {}, Noop.onLine),
    );
}

test "collectOwnedLinesUntilEnd strips tabs and skips empty values" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "\tfirst",
        "\t",
        "second",
        "@@ZPRJ_REQ_END 7",
    } };

    const lines = try collectOwnedLinesUntilEnd(
        allocator,
        &reader,
        64,
        "@@ZPRJ_REQ_END",
        7,
        .{
            .strip_leading_tab = true,
            .skip_empty = true,
        },
    );
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("first", lines[0]);
    try std.testing.expectEqualStrings("second", lines[1]);
}

test "collectOwnedLinesUntilEnd enforces max_bytes" {
    const allocator = std.testing.allocator;
    var reader = TestReader{ .lines = &.{
        "aaa",
        "bbb",
        "ccc",
        "@@ZPRJ_REQ_END 1",
    } };

    const result = collectOwnedLinesUntilEnd(
        allocator,
        &reader,
        64,
        "@@ZPRJ_REQ_END",
        1,
        .{
            .strip_leading_tab = false,
            .skip_empty = false,
            .max_bytes = 4,
        },
    );
    try std.testing.expectError(error.StreamTooLong, result);
}
