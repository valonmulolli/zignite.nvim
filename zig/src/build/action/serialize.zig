const std = @import("std");
const common = @import("../../project/core/common.zig");
const system_command = @import("../../system_command.zig");
const plan_impl = @import("plan.zig");
const types = @import("types.zig");

pub fn writeResolvedPlan(
    stdout: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: types.Options,
) !void {
    var plan = try plan_impl.resolvePlan(io, allocator, environ_map, options);
    defer plan.deinit(allocator);

    var wrapped_argv: std.ArrayList([]u8) = .empty;
    defer system_command.deinitOwnedArgv(allocator, &wrapped_argv);
    if (plan.ok) {
        if (plan.exec_command) |command_text| {
            wrapped_argv = try system_command.buildSystemArgvWithIO(io, allocator, command_text, plan.exec_argv.items, null);
        }
    }

    try writePlanJson(stdout, allocator, plan, wrapped_argv.items);
    try writePlanLegacy(stdout, plan);
}

fn writePlanJson(
    stdout: anytype,
    allocator: std.mem.Allocator,
    plan: types.Plan,
    wrapped_argv: []const []u8,
) !void {
    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();

    try std.json.Stringify.value(PlanJson{ .plan = plan, .system_argv = wrapped_argv }, .{}, &json_out.writer);
    try stdout.print("RESULT_JSON\t{s}\n", .{json_out.written()});
}

fn writePlanLegacy(stdout: anytype, plan: types.Plan) !void {
    try stdout.print("OK\t{d}\n", .{if (plan.ok) @as(u8, 1) else @as(u8, 0)});
    if (plan.reason) |reason| {
        try stdout.print("REASON\t{s}\n", .{@tagName(reason)});
    }
    if (plan.message) |message| {
        if (!common.hasInvalidPayloadChars(message)) {
            try stdout.print("MESSAGE\t{s}\n", .{message});
        }
    }
    if (plan.resolved_command_name) |name| {
        if (!common.hasInvalidPayloadChars(name)) {
            try stdout.print("COMMAND_NAME\t{s}\n", .{name});
        }
    }
    if (plan.requires_arguments) {
        try stdout.print("REQUIRES_ARGUMENTS\t1\n", .{});
    }
    if (plan.argument_prompt) |prompt| {
        if (!common.hasInvalidPayloadChars(prompt)) {
            try stdout.print("ARGUMENT_PROMPT\t{s}\n", .{prompt});
        }
    }
    if (plan.argument_help) |help| {
        if (!common.hasInvalidPayloadChars(help)) {
            try stdout.print("ARGUMENT_HELP\t{s}\n", .{help});
        }
    }
    if (plan.filetype) |filetype| {
        if (!common.hasInvalidPayloadChars(filetype)) {
            try stdout.print("FILETYPE\t{s}\n", .{filetype});
        }
    }
    if (plan.cwd) |cwd| {
        if (!common.hasInvalidPayloadChars(cwd)) {
            try stdout.print("CWD\t{s}\n", .{cwd});
        }
    }
    if (plan.name) |name| {
        if (!common.hasInvalidPayloadChars(name)) {
            try stdout.print("NAME\t{s}\n", .{name});
        }
    }
    if (plan.exec_command) |command_text| {
        if (!common.hasInvalidPayloadChars(command_text)) {
            try stdout.print("EXEC_COMMAND\t{s}\n", .{command_text});
        }
    }
    for (plan.exec_argv.items) |arg| {
        if (!common.hasInvalidPayloadChars(arg)) {
            try stdout.print("EXEC_ARGV\t{s}\n", .{arg});
        }
    }
    try stdout.print("CONFIG_REVISION\t{d}\n", .{plan.config_revision});
}

const PlanJson = struct {
    plan: types.Plan,
    system_argv: []const []u8,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        const plan = self.plan;
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(plan.ok);
        if (plan.reason) |reason| {
            try jw.objectField("reason");
            try jw.write(@tagName(reason));
        }
        if (plan.message) |message| {
            try jw.objectField("message");
            try jw.write(message);
        }
        if (plan.resolved_command_name) |name| {
            try jw.objectField("resolved_command_name");
            try jw.write(name);
        }
        if (plan.requires_arguments) {
            try jw.objectField("requires_arguments");
            try jw.write(true);
        }
        if (plan.argument_prompt) |prompt| {
            try jw.objectField("argument_prompt");
            try jw.write(prompt);
        }
        if (plan.argument_help) |help| {
            try jw.objectField("argument_help");
            try jw.write(help);
        }
        if (plan.filetype) |filetype| {
            try jw.objectField("filetype");
            try jw.write(filetype);
        }
        if (plan.cwd) |cwd| {
            try jw.objectField("cwd");
            try jw.write(cwd);
        }
        if (plan.name) |name| {
            try jw.objectField("name");
            try jw.write(name);
        }
        if (plan.exec_command) |command_text| {
            try jw.objectField("exec_command");
            try jw.write(command_text);
        }
        if (plan.exec_argv.items.len > 0) {
            try jw.objectField("exec_argv");
            try jw.write(plan.exec_argv.items);
        }
        if (self.system_argv.len > 0) {
            try jw.objectField("system_argv");
            try jw.write(self.system_argv);
        }
        try jw.objectField("config_revision");
        try jw.write(plan.config_revision);
        try jw.endObject();
    }
};
