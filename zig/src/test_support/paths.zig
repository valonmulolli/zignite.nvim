const std = @import("std");
const common = @import("../project/core/common.zig");

pub fn expectEqualPath(expected: []const u8, actual: []const u8) !void {
    const allocator = std.testing.allocator;
    const normalized_expected = try common.normalizePathAlloc(allocator, expected);
    defer allocator.free(normalized_expected);
    const normalized_actual = try common.normalizePathAlloc(allocator, actual);
    defer allocator.free(normalized_actual);
    try std.testing.expectEqualStrings(normalized_expected, normalized_actual);
}
