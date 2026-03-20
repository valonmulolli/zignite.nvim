const std = @import("std");
const common = @import("common.zig");

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
        } else if (std.mem.eql(u8, section, "tool.poetry")) {
            try common.pushUniqueName(allocator, names, "poetry");
        } else if (std.mem.eql(u8, section, "tool.pdm")) {
            try common.pushUniqueName(allocator, names, "pdm");
        } else if (std.mem.eql(u8, section, "tool.hatch") or std.mem.eql(u8, section, "tool.hatch.envs")) {
            try common.pushUniqueName(allocator, names, "hatch");
        }
    }
}

fn stripHashComment(line: []const u8) []const u8 {
    const hash_idx = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash_idx];
}

test "parse pyproject tool sections" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);

    try parseTools(
        allocator,
        \\[project]
        \\name = "demo"
        \\
        \\[tool.uv]
        \\dev-dependencies = []
        \\
        \\[tool.poetry]
        \\name = "demo"
        \\
        \\[tool.hatch.envs.default]
        \\dependencies = []
    , &names);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("uv", names.items[0]);
    try std.testing.expectEqualStrings("poetry", names.items[1]);
    try std.testing.expectEqualStrings("hatch", names.items[2]);
}
