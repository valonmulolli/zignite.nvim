const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseTools(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    var multiline_quote: ?MultilineQuote = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(stripHashComment(common.stripTrailingCR(raw_line), &multiline_quote));
        if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') continue;

        const section = line[1 .. line.len - 1];
        if (std.mem.eql(u8, section, "tool.uv")) {
            try common.pushUniqueName(allocator, names, "uv");
        }
    }
}

pub fn hasToolSection(contents: []const u8, tool_section: []const u8) bool {
    var multiline_quote: ?MultilineQuote = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(stripHashComment(common.stripTrailingCR(raw_line), &multiline_quote));
        if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') continue;
        const section = line[1 .. line.len - 1];
        if (std.mem.eql(u8, section, tool_section)) return true;
    }
    return false;
}

const MultilineQuote = enum { basic, literal };

fn stripHashComment(line: []const u8, multiline_quote: *?MultilineQuote) []const u8 {
    var index: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    while (index < line.len) {
        const ch = line[index];

        if (multiline_quote.*) |active_multiline| {
            const delimiter: u8 = if (active_multiline == .basic) '"' else '\'';
            if (hasTripleQuote(line, index, delimiter) and
                (active_multiline == .literal or !isEscaped(line, index)))
            {
                multiline_quote.* = null;
                index += 3;
                continue;
            }
            index += 1;
            continue;
        }

        if (quote) |active_quote| {
            if (active_quote == '"' and escaped) {
                escaped = false;
                index += 1;
                continue;
            }
            if (active_quote == '"' and ch == '\\') {
                escaped = true;
                index += 1;
                continue;
            }
            if (ch == active_quote) {
                quote = null;
            }
            index += 1;
            continue;
        }

        if (hasTripleQuote(line, index, ch)) {
            multiline_quote.* = if (ch == '"') .basic else .literal;
            index += 3;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            index += 1;
            continue;
        }
        if (ch == '#') return line[0..index];
        index += 1;
    }

    if (multiline_quote.* != null) return line[0..0];
    return line;
}

fn hasTripleQuote(line: []const u8, index: usize, quote: u8) bool {
    return (quote == '"' or quote == '\'') and index + 3 <= line.len and
        line[index] == quote and line[index + 1] == quote and line[index + 2] == quote;
}

fn isEscaped(line: []const u8, index: usize) bool {
    var slash_count: usize = 0;
    var cursor = index;
    while (cursor > 0 and line[cursor - 1] == '\\') : (cursor -= 1) {
        slash_count += 1;
    }
    return slash_count % 2 == 1;
}

test "parse pyproject tool sections" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTools(allocator,
        \\[project]
        \\name = "demo"
        \\
        \\[tool.uv]
        \\dev-dependencies = []
    , &names);

    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("uv", names.items[0]);
}

test "detect specific tool section" {
    try std.testing.expect(hasToolSection(
        \\[project]
        \\name = "demo"
        \\
        \\[tool.uv]
        \\dev-dependencies = []
    , "tool.uv"));
    try std.testing.expect(!hasToolSection(
        \\[project]
        \\name = "demo"
        \\
        \\[tool.other]
        \\enabled = true
    , "tool.uv"));
}

test "ignore section-looking lines inside multiline strings" {
    const contents =
        \\description = """
        \\[tool.uv]
        \\"""
    ;

    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTools(allocator, contents, &names);
    try std.testing.expectEqual(@as(usize, 0), names.items.len);
    try std.testing.expect(!hasToolSection(contents, "tool.uv"));
}
