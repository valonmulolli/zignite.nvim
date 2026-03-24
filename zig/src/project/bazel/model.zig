const std = @import("std");
const common = @import("../core/common.zig");

pub const Target = struct {
    rule_name: []u8,
    name: []u8,
    supports_run: bool,
    supports_test: bool,
    source_entries: [][]u8,
};

pub const CommandEntry = struct {
    name: []u8,
    command: []u8,
};

pub const CommandInfo = struct {
    commands: []CommandEntry,
    primary_build: ?[]u8 = null,
    primary_run: ?[]u8 = null,
    primary_test: ?[]u8 = null,
};

pub fn freeOwnedTargets(allocator: std.mem.Allocator, items: []Target) void {
    for (items) |item| {
        allocator.free(item.rule_name);
        allocator.free(item.name);
        common.freeOwnedNameList(allocator, item.source_entries);
    }
    allocator.free(items);
}

pub fn freeOwnedCommandInfo(allocator: std.mem.Allocator, info: CommandInfo) void {
    for (info.commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    allocator.free(info.commands);
    if (info.primary_build) |value| allocator.free(value);
    if (info.primary_run) |value| allocator.free(value);
    if (info.primary_test) |value| allocator.free(value);
}
