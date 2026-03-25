const std = @import("std");

pub fn canonicalizeDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = trimSpaces(line);
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "-->")) {
        trimmed = trimSpaces(trimmed[3..]);
    }

    if (try parseParenDiagnostic(allocator, trimmed)) |diag| return diag;
    if (try parseColonDiagnostic(allocator, trimmed)) |diag| return diag;
    return null;
}

fn parseColonDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;

        const line_start = i + 1;
        var j = line_start;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        if (j == line_start or j >= line.len or line[j] != ':') continue;

        const line_no = std.fmt.parseInt(usize, line[line_start..j], 10) catch continue;
        const path = trimSpaces(line[0..i]);
        if (path.len == 0 or std.mem.indexOfAny(u8, path, "/\\.") == null) continue;

        const after_line = j + 1;
        var k = after_line;
        while (k < line.len and std.ascii.isDigit(line[k])) : (k += 1) {}

        var col_no: usize = 1;
        var msg_start = after_line;
        if (k > after_line and k < line.len and line[k] == ':') {
            col_no = std.fmt.parseInt(usize, line[after_line..k], 10) catch 1;
            msg_start = k + 1;
        }

        const msg = trimSpaces(line[msg_start..]);
        const normalized_msg = if (msg.len == 0) "diagnostic" else msg;
        return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ path, line_no, col_no, normalized_msg });
    }
    return null;
}

fn parseParenDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const colon_idx = std.mem.indexOfScalarPos(u8, line, open_idx + 1, ':') orelse return null;
    const close_idx = std.mem.indexOfScalarPos(u8, line, colon_idx + 1, ')') orelse return null;

    const path = trimSpaces(line[0..open_idx]);
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "/\\.") == null) return null;

    const line_no = std.fmt.parseInt(usize, line[open_idx + 1 .. colon_idx], 10) catch return null;
    const col_no = std.fmt.parseInt(usize, line[colon_idx + 1 .. close_idx], 10) catch return null;
    const msg = trimSpaces(line[close_idx + 1 ..]);
    const normalized_msg = if (msg.len == 0) "diagnostic" else msg;

    return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ path, line_no, col_no, normalized_msg });
}

fn trimSpaces(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and std.ascii.isWhitespace(input[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}
