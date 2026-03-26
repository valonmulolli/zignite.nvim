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

