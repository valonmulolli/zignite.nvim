const std = @import("std");
const build_types = @import("../system/types.zig");

pub const Options = struct {
    path: []const u8,
    filetype: []const u8,
    command_name: ?[]const u8 = null,
    command_args: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
};

pub const ResolvedOutput = struct {
    filetype: ?[]u8 = null,
    root: ?[]u8 = null,
    system: ?[]u8 = null,
    build_ready: ?bool = null,
    commands: std.ArrayList(build_types.CommandEntry) = .empty,
    preferred: std.ArrayList(build_types.CommandEntry) = .empty,

    pub fn deinit(self: *ResolvedOutput, allocator: std.mem.Allocator) void {
        if (self.filetype) |filetype| allocator.free(filetype);
        if (self.root) |root| allocator.free(root);
        if (self.system) |system| allocator.free(system);
        freeOwnedCommands(allocator, self.commands.items);
        self.commands.deinit(allocator);
        freeOwnedCommands(allocator, self.preferred.items);
        self.preferred.deinit(allocator);
    }
};

pub fn freeOwnedCommands(allocator: std.mem.Allocator, commands: []build_types.CommandEntry) void {
    for (commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
}
