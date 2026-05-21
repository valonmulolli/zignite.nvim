const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseModuleName(allocator: std.mem.Allocator, contents: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(stripLineComment(common.stripTrailingCR(raw_line)));
        if (!std.mem.startsWith(u8, line, "module")) continue;
        if (line.len > "module".len and !isWhitespace(line["module".len])) continue;

        const value = common.trimSpaces(line["module".len..]);
        if (value.len == 0) return null;
        return try allocator.dupe(u8, stripQuotes(value));
    }
    return null;
}

fn stripLineComment(line: []const u8) []const u8 {
    const idx = std.mem.find(u8, line, "//") orelse return line;
    return line[0..idx];
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'') or (first == '`' and last == '`')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

test "parse go module name" {
    const allocator = std.testing.allocator;
    const name = try parseModuleName(
        allocator,
        \\module example.com/demo
        \\
        \\go 1.24.0
    );
    defer if (name) |value| allocator.free(value);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("example.com/demo", name.?);
}
