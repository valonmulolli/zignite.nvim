const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseTools(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(stripHashComment(common.stripTrailingCR(raw_line)));
        if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') continue;

        const section = line[1 .. line.len - 1];
        if (std.mem.eql(u8, section, "tool.uv")) {
            try common.pushUniqueName(allocator, names, "uv");
        }
    }
}

pub fn hasToolSection(contents: []const u8, tool_section: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(stripHashComment(common.stripTrailingCR(raw_line)));
        if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') continue;
        const section = line[1 .. line.len - 1];
        if (std.mem.eql(u8, section, tool_section)) return true;
    }
    return false;
}

fn stripHashComment(line: []const u8) []const u8 {
    const hash_idx = std.mem.findScalar(u8, line, '#') orelse return line;
    return line[0..hash_idx];
}

test "parse pyproject tool sections" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTools(
        allocator,
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
