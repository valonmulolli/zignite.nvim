const std = @import("std");

pub fn dirOrDot(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

test "dirOrDot uses dot for bare relative paths" {
    try std.testing.expectEqualStrings(".", dirOrDot("main.zig"));
    try std.testing.expectEqualStrings("src", dirOrDot("src/main.zig"));
    try std.testing.expectEqualStrings("/tmp/demo", dirOrDot("/tmp/demo/main.zig"));
}
