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
