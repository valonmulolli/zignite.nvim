const std = @import("std");

pub const Tool = enum {
    zig,
    go,
    cargo,
    odin,
};

pub const Options = struct {
    tool: Tool,
};

pub fn parseTool(value: []const u8) !Tool {
    if (std.ascii.eqlIgnoreCase(value, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(value, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(value, "cargo")) return .cargo;
    if (std.ascii.eqlIgnoreCase(value, "odin")) return .odin;
    return error.InvalidDetectTool;
}

pub fn freeOwnedCommandList(allocator: std.mem.Allocator, commands: [][]u8) void {
    for (commands) |command| {
        allocator.free(command);
    }
    allocator.free(commands);
}

test "parseTool accepts case-insensitive tool names" {
    try std.testing.expectEqual(Tool.zig, try parseTool("zig"));
    try std.testing.expectEqual(Tool.zig, try parseTool("ZIG"));
    try std.testing.expectEqual(Tool.go, try parseTool("go"));
    try std.testing.expectEqual(Tool.cargo, try parseTool("CARGO"));
    try std.testing.expectEqual(Tool.odin, try parseTool("Odin"));
}

test "parseTool rejects unknown tool names" {
    try std.testing.expectError(error.InvalidDetectTool, parseTool("ruby"));
    try std.testing.expectError(error.InvalidDetectTool, parseTool("python"));
    try std.testing.expectError(error.InvalidDetectTool, parseTool(""));
}
