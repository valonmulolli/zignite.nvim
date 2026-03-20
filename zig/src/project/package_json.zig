const std = @import("std");
const common = @import("common.zig");

pub fn parseScripts(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const scripts = root.object.get("scripts") orelse return;
    if (scripts != .object) return;

    var it = scripts.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try common.pushUniqueName(allocator, names, entry.key_ptr.*);
    }
}

test "parse package scripts" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    try parseScripts(
        allocator,
        \\{"scripts":{"dev":"vite","build":"vite build","test":"vitest"}}
    , &names);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
}
