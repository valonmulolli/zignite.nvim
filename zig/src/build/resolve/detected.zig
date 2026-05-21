const std = @import("std");
const builtin = @import("detected/builtin.zig");
const build_types = @import("../system/types.zig");
const collect = @import("detected/collect.zig");
const output = @import("detected/output.zig");
const policy = @import("detected/policy.zig");
const types = @import("types.zig");

pub fn resolveOutput(allocator: std.mem.Allocator, options: types.Options) !types.ResolvedOutput {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return resolveOutputWithIO(threaded.io(), allocator, options);
}

pub fn resolveOutputWithIO(io: std.Io, allocator: std.mem.Allocator, options: types.Options) !types.ResolvedOutput {
    var parsed_output = try collect.resolveDetectedOutputWithIO(io, allocator, options);
    errdefer parsed_output.deinit(allocator);
    const resolved_filetype = parsed_output.filetype orelse options.filetype;

    const builtin_commands = try builtin.listBuildCommands(allocator, resolved_filetype);
    defer {
        types.freeOwnedCommands(allocator, builtin_commands);
        allocator.free(builtin_commands);
    }
    try overlayBuiltinCommands(
        allocator,
        resolved_filetype,
        parsed_output.system,
        &parsed_output,
        builtin_commands,
    );

    const configured = try collect.collectConfiguredCommands(allocator, resolved_filetype, options.path);
    defer {
        types.freeOwnedCommands(allocator, configured);
        allocator.free(configured);
    }
    try overlayCommands(allocator, resolved_filetype, &parsed_output, configured);
    return parsed_output;
}

fn overlayBuiltinCommands(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    detected_system: ?[]const u8,
    parsed_output: *types.ResolvedOutput,
    entries: []const build_types.CommandEntry,
) !void {
    for (entries) |entry| {
        if (!policy.shouldOverlayBuiltinCommand(
            filetype,
            detected_system,
            parsed_output.commands.items,
            entry,
        )) continue;
        try output.upsertOwnedCommand(&parsed_output.commands, allocator, entry.name, entry.command);
    }
}

fn overlayCommands(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    parsed_output: *types.ResolvedOutput,
    entries: []const build_types.CommandEntry,
) !void {
    for (entries) |entry| {
        if (!policy.shouldOverlayConfiguredCommand(
            filetype,
            parsed_output.system,
            parsed_output.commands.items,
            entry,
        )) continue;
        try output.upsertOwnedCommand(&parsed_output.commands, allocator, entry.name, entry.command);
    }
}

pub const resolveDetectedOutput = collect.resolveDetectedOutput;
pub const resolveDetectedOutputWithIO = collect.resolveDetectedOutputWithIO;
pub const appendImplicitPreferred = output.appendImplicitPreferred;
pub const findCommand = output.findCommand;
pub const findPreferredCommandName = output.findPreferredCommandName;
