const std = @import("std");
const builtin = @import("builtin.zig");
const filetype_policy = @import("../../../filetype_policy.zig");
const config_view = @import("../../../config/view.zig");
const build_types = @import("../../system/types.zig");
const output = @import("output.zig");

pub fn autoKindForFiletype(filetype: []const u8) ?@import("../../../project/core/types.zig").Kind {
    return filetype_policy.autoKindForFiletype(filetype);
}

pub fn systemQueryForFiletype(filetype: []const u8) ?@import("../../system.zig").Query {
    return filetype_policy.systemQueryForFiletype(filetype);
}

pub fn isDetectionEnabled(filetype: []const u8) bool {
    return config_view.isDetectEnabled(filetype);
}

pub fn shouldOverlayBuiltinCommand(
    filetype: []const u8,
    detected_system: ?[]const u8,
    commands: []const build_types.CommandEntry,
    command_entry: build_types.CommandEntry,
) bool {
    if (builtin.commandSystem(filetype, command_entry.name)) |builtin_system| {
        const system = detected_system orelse return false;
        if (!std.mem.eql(u8, builtin_system, system)) {
            return false;
        }
    }
    return shouldOverlayCommand(filetype, detected_system, commands, command_entry);
}

pub fn shouldOverlayConfiguredCommand(
    filetype: []const u8,
    detected_system: ?[]const u8,
    commands: []const build_types.CommandEntry,
    command_entry: build_types.CommandEntry,
) bool {
    _ = commands;
    if (detected_system) |system| {
        if (builtin.commandSystem(filetype, command_entry.name)) |builtin_system| {
            return std.mem.eql(u8, builtin_system, system);
        }
    }
    return true;
}

fn shouldOverlayCommand(
    filetype: []const u8,
    detected_system: ?[]const u8,
    commands: []const build_types.CommandEntry,
    command_entry: build_types.CommandEntry,
) bool {
    if (detected_system) |system| {
        if (builtin.commandSystem(filetype, command_entry.name)) |builtin_system| {
            if (!std.mem.eql(u8, builtin_system, system)) {
                return false;
            }
        }
    }

    return output.findCommand(commands, command_entry.name) == null;
}
