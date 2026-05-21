const std = @import("std");
const config = @import("../../config.zig");
const system_types = @import("../../build/system/types.zig");
const resolve_types = @import("../resolve/types.zig");
const command = @import("../resolve/command.zig");
const detected = @import("../resolve/detected.zig");
const selected = @import("../resolve/selected.zig");
const state = @import("state.zig");
const types = @import("types.zig");

const ActionTarget = struct {
    resolved_filetype: []const u8,
    command_name: []const u8,
    command_template: []const u8,
    owns_command_name: bool = false,

    fn deinit(self: ActionTarget, allocator: std.mem.Allocator) void {
        if (self.owns_command_name) allocator.free(self.command_name);
    }
};

const ActionSelection = union(enum) {
    target: ActionTarget,
    plan: types.Plan,
};

pub fn resolvePlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    options: types.Options,
) !types.Plan {
    var parsed_output = try detected.resolveOutputWithIO(io, allocator, .{
        .path = options.path,
        .filetype = options.filetype,
        .project_root = options.project_root,
    });
    defer parsed_output.deinit(allocator);

    const selection = try resolveActionTarget(io, allocator, environ_map, options, &parsed_output);
    const target = switch (selection) {
        .target => |value| value,
        .plan => |plan| return plan,
    };
    defer target.deinit(allocator);
    if (command.commandRequiresArguments(target.command_template) and !hasProvidedArguments(options.command_args)) {
        return missingArgumentsPlan(allocator, target.resolved_filetype, target.command_name);
    }

    var plan = try resolveSelectedPlan(io, allocator, .{
        .path = options.path,
        .filetype = options.filetype,
        .action = options.action,
        .command_name = target.command_name,
        .command_args = options.command_args,
        .project_root = options.project_root,
    }, target.command_name);
    errdefer plan.deinit(allocator);

    try state.setLastCommand(io, allocator, environ_map, target.resolved_filetype, target.command_name);
    return plan;
}

fn resolveActionTarget(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    options: types.Options,
    parsed_output: *resolve_types.ResolvedOutput,
) !ActionSelection {
    const resolved_filetype = parsed_output.filetype orelse options.filetype;

    return switch (options.action) {
        .named => blk: {
            const command_name = options.command_name orelse return .{ .plan = try missingNamedCommandPlan(
                allocator,
                options.filetype,
                "",
                &.{},
            ) };
            const command_template = detected.findCommand(parsed_output.commands.items, command_name) orelse
                return .{ .plan = try missingNamedCommandPlan(allocator, resolved_filetype, command_name, parsed_output.commands.items) };
            break :blk .{ .target = .{
                .resolved_filetype = resolved_filetype,
                .command_name = command_name,
                .command_template = command_template,
            } };
        },
        .live => blk: {
            if (parsed_output.preferred.items.len == 0) {
                try detected.appendImplicitPreferred(allocator, &parsed_output.preferred, parsed_output.commands.items);
            }
            const live_name = detected.findPreferredCommandName(
                parsed_output.preferred.items,
                parsed_output.commands.items,
                &[_][]const u8{"live"},
            ) orelse return .{ .plan = try missingLiveCommandPlan(allocator, resolved_filetype) };
            const command_template = detected.findCommand(parsed_output.commands.items, live_name) orelse
                return .{ .plan = try missingLiveCommandPlan(allocator, resolved_filetype) };
            break :blk .{ .target = .{
                .resolved_filetype = resolved_filetype,
                .command_name = live_name,
                .command_template = command_template,
            } };
        },
        .last => blk: {
            const stored_command_name = (try state.getLastCommand(io, allocator, environ_map, resolved_filetype)) orelse
                return .{ .plan = try missingLastCommandPlan(allocator, resolved_filetype) };
            const last_command_name = try allocator.dupe(u8, stored_command_name);
            errdefer allocator.free(last_command_name);
            if (std.mem.trim(u8, last_command_name, " \t\r\n").len == 0) {
                allocator.free(last_command_name);
                return .{ .plan = try missingLastCommandPlan(allocator, resolved_filetype) };
            }
            const command_template = detected.findCommand(parsed_output.commands.items, last_command_name) orelse
                {
                    defer allocator.free(last_command_name);
                    state.clearLastCommand(io, allocator, environ_map, resolved_filetype);
                    return .{ .plan = try staleLastCommandPlan(allocator, resolved_filetype, last_command_name, parsed_output.commands.items) };
                };
            break :blk .{ .target = .{
                .resolved_filetype = resolved_filetype,
                .command_name = last_command_name,
                .command_template = command_template,
                .owns_command_name = true,
            } };
        },
    };
}

fn resolveSelectedPlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: types.Options,
    resolved_name: []const u8,
) !types.Plan {
    var resolved = try selected.resolveCommandExecutionWithIO(io, allocator, .{
        .path = options.path,
        .filetype = options.filetype,
        .command_name = resolved_name,
        .command_args = options.command_args,
        .project_root = options.project_root,
    });
    defer resolved.deinit(allocator);

    var plan = types.Plan{
        .ok = true,
        .config_revision = config.getSyncedRevision(),
    };
    errdefer plan.deinit(allocator);

    try plan.exec_argv.ensureTotalCapacity(allocator, resolved.exec_argv.items.len);
    for (resolved.exec_argv.items) |arg| {
        plan.exec_argv.appendAssumeCapacity(try allocator.dupe(u8, arg));
    }

    plan.resolved_command_name = try allocator.dupe(u8, resolved.command_name);
    plan.filetype = try allocator.dupe(u8, resolved.filetype);
    plan.cwd = try allocator.dupe(u8, resolved.cwd);
    plan.name = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ resolved.filetype, resolved.command_name });
    plan.exec_command = try allocator.dupe(u8, resolved.exec_command);

    return plan;
}

fn missingLiveCommandPlan(allocator: std.mem.Allocator, filetype: []const u8) !types.Plan {
    var plan = types.Plan{
        .ok = false,
        .reason = .missing_live_command,
        .config_revision = config.getSyncedRevision(),
    };
    errdefer plan.deinit(allocator);

    plan.message = try std.fmt.allocPrint(allocator, "No live command resolved for {s}.", .{filetype});
    plan.filetype = try allocator.dupe(u8, filetype);
    return plan;
}

fn missingNamedCommandPlan(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
    commands: []const system_types.CommandEntry,
) !types.Plan {
    var plan = types.Plan{
        .ok = false,
        .reason = .missing_command,
        .config_revision = config.getSyncedRevision(),
    };
    errdefer plan.deinit(allocator);

    plan.message = if (commands.len == 0)
        try std.fmt.allocPrint(allocator, "No build commands available for filetype: {s}", .{filetype})
    else
        try missingCommandMessageAlloc(allocator, filetype, command_name, commands);
    if (command_name.len > 0) {
        plan.resolved_command_name = try allocator.dupe(u8, command_name);
    }
    plan.filetype = try allocator.dupe(u8, filetype);
    return plan;
}

fn missingArgumentsPlan(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
) !types.Plan {
    var plan = types.Plan{
        .ok = false,
        .reason = .missing_arguments,
        .requires_arguments = true,
        .config_revision = config.getSyncedRevision(),
    };
    errdefer plan.deinit(allocator);

    plan.message = try std.fmt.allocPrint(
        allocator,
        "Command '{s}' for {s} requires additional arguments.",
        .{ command_name, filetype },
    );
    plan.resolved_command_name = try allocator.dupe(u8, command_name);
    plan.argument_prompt = try command.commandArgumentPromptAlloc(allocator, filetype, command_name);
    plan.argument_help = try command.commandArgumentHelpAlloc(allocator, filetype, command_name);
    plan.filetype = try allocator.dupe(u8, filetype);
    return plan;
}

fn missingLastCommandPlan(allocator: std.mem.Allocator, filetype: []const u8) !types.Plan {
    var plan = types.Plan{
        .ok = false,
        .reason = .missing_last_command,
        .config_revision = config.getSyncedRevision(),
    };
    errdefer plan.deinit(allocator);

    plan.message = try std.fmt.allocPrint(allocator, "No previous build command for filetype: {s}", .{filetype});
    plan.filetype = try allocator.dupe(u8, filetype);
    return plan;
}

fn staleLastCommandPlan(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
    commands: []const system_types.CommandEntry,
) !types.Plan {
    var plan = types.Plan{
        .ok = false,
        .reason = .stale_last_command,
        .config_revision = config.getSyncedRevision(),
    };
    errdefer plan.deinit(allocator);

    plan.message = try missingCommandMessageAlloc(allocator, filetype, command_name, commands);
    plan.resolved_command_name = try allocator.dupe(u8, command_name);
    plan.filetype = try allocator.dupe(u8, filetype);
    return plan;
}

fn missingCommandMessageAlloc(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    command_name: []const u8,
    commands: []const system_types.CommandEntry,
) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try names.ensureTotalCapacity(allocator, commands.len);
    for (commands) |entry| {
        names.appendAssumeCapacity(entry.name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    const available = try std.mem.join(allocator, ", ", names.items);
    defer allocator.free(available);
    return std.fmt.allocPrint(
        allocator,
        "Command '{s}' not found for {s}.\nAvailable commands: {s}",
        .{ command_name, filetype, available },
    );
}

fn hasProvidedArguments(command_args: ?[]const u8) bool {
    const value = command_args orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}
