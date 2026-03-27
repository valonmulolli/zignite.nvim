const std = @import("std");

pub const Options = struct {
    path: []const u8,
    filetype: []const u8,
    context_path: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
};

pub const ResolvedRunner = struct {
    source: []const u8 = "filetype",
    filetype: ?[]u8 = null,
    command: ?[]u8 = null,
    cleanup_command: ?[]u8 = null,
    cwd: ?[]u8 = null,
    name: ?[]u8 = null,
    argv: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ResolvedRunner, allocator: std.mem.Allocator) void {
        if (self.filetype) |filetype| allocator.free(filetype);
        if (self.command) |command| allocator.free(command);
        if (self.cleanup_command) |cleanup| allocator.free(cleanup);
        if (self.cwd) |cwd| allocator.free(cwd);
        if (self.name) |name| allocator.free(name);
        for (self.argv.items) |arg| allocator.free(arg);
        self.argv.deinit(allocator);
    }
};
