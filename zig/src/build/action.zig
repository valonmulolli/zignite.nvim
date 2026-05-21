const std = @import("std");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");
const system_command = @import("../system_command.zig");
const protocol = @import("action/protocol.zig");
const plan_impl = @import("action/plan.zig");
const serialize = @import("action/serialize.zig");
const types = @import("action/types.zig");

pub const BUILD_ACTION_REQ_BEGIN = protocol.BUILD_ACTION_REQ_BEGIN;
pub const BUILD_ACTION_REQ_END = protocol.BUILD_ACTION_REQ_END;
pub const BUILD_ACTION_RES_BEGIN = protocol.BUILD_ACTION_RES_BEGIN;
pub const BUILD_ACTION_RES_END = protocol.BUILD_ACTION_RES_END;
pub const BUILD_ACTION_RES_ERR = protocol.BUILD_ACTION_RES_ERR;
pub const BUILD_ACTION_MAX_LINE = protocol.BUILD_ACTION_MAX_LINE;

pub const Action = types.Action;
pub const Options = types.Options;
pub const FailureReason = types.FailureReason;
pub const Plan = types.Plan;

pub const parseArgs = protocol.parseArgs;
pub const resolvePlan = plan_impl.resolvePlan;

pub fn runMode(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    return runModeWithEnviron(allocator, io, null, options);
}

pub fn runModeWithEnviron(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !void {
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();
    try serialize.writeResolvedPlan(stdout, allocator, io, environ_map, options);
    try stdout.flush();
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = protocol.parseDaemonBegin(begin_line) catch |err| {
        if (frame.parseRequestId(begin_line, BUILD_ACTION_REQ_BEGIN)) |request_id| {
            try frame.writeErrorResponse(
                stdout,
                BUILD_ACTION_RES_BEGIN,
                BUILD_ACTION_RES_ERR,
                BUILD_ACTION_RES_END,
                request_id,
                @errorName(err),
            );
            try stdout.flush();
            return;
        }
        return err;
    };

    const request_args = try frame.collectOwnedLinesUntilEnd(
        allocator,
        reader,
        BUILD_ACTION_MAX_LINE,
        BUILD_ACTION_REQ_END,
        header.request_id,
        .{
            .strip_leading_tab = true,
            .skip_empty = true,
        },
    );
    defer {
        for (request_args) |arg| allocator.free(arg);
        allocator.free(request_args);
    }

    try stdout.print("{s} {d}\n", .{ BUILD_ACTION_RES_BEGIN, header.request_id });
    const options = parseArgs(request_args);
    if (options) |parsed| {
        serialize.writeResolvedPlan(stdout, allocator, io, environ_map, parsed) catch |err| {
            try stdout.print("{s} {d} {s}\n", .{ BUILD_ACTION_RES_ERR, header.request_id, @errorName(err) });
        };
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ BUILD_ACTION_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ BUILD_ACTION_RES_END, header.request_id });
    try stdout.flush();
}

test "resolve live plan json includes wrapped system argv" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"webft":{"live":"npm run live"}},"detect":{},"timeout":1200,"revision":81}
    , 81);

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/webft/main.ts",
        .filetype = "webft",
        .action = .live,
    });
    defer plan.deinit(allocator);

    var wrapped_argv = try system_command.buildSystemArgv(allocator, plan.exec_command.?, plan.exec_argv.items, null);
    defer system_command.deinitOwnedArgv(allocator, &wrapped_argv);

    try std.testing.expect(wrapped_argv.items.len >= 6);
    try std.testing.expectEqualStrings("--timeout=1200", wrapped_argv.items[1]);
    try std.testing.expectEqualStrings("--argv", wrapped_argv.items[2]);
    try std.testing.expectEqualStrings("npm", wrapped_argv.items[3]);
    try std.testing.expectEqualStrings("run", wrapped_argv.items[4]);
    try std.testing.expectEqualStrings("live", wrapped_argv.items[5]);
}

pub fn jsonStringify(self: Plan, jw: anytype) !void {
    try types.Plan.jsonStringify(self, jw);
}

test "resolve live plan returns execution payload" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"webft":{"live":"npm run live"}},"detect":{},"revision":81}
    , 81);

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/webft/main.ts",
        .filetype = "webft",
        .action = .live,
    });
    defer plan.deinit(allocator);

    try std.testing.expect(plan.ok);
    try std.testing.expectEqualStrings("live", plan.resolved_command_name.?);
    try std.testing.expectEqualStrings("npm run live", plan.exec_command.?);
    try std.testing.expectEqualStrings("webft: live", plan.name.?);
    try std.testing.expectEqualStrings("/tmp/webft", plan.cwd.?);
}

test "resolve named plan returns execution payload" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"namedft":{"test":"pytest -q"}},"detect":{},"revision":80}
    , 80);

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/namedft/main.py",
        .filetype = "namedft",
        .action = .named,
        .command_name = "test",
    });
    defer plan.deinit(allocator);

    try std.testing.expect(plan.ok);
    try std.testing.expectEqualStrings("test", plan.resolved_command_name.?);
    try std.testing.expectEqualStrings("pytest -q", plan.exec_command.?);
    try std.testing.expectEqualStrings("namedft: test", plan.name.?);
}

test "resolve live plan reports missing live command" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"nolive":{"build":"echo build"}},"detect":{},"revision":82}
    , 82);

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/nolive/main.txt",
        .filetype = "nolive",
        .action = .live,
    });
    defer plan.deinit(allocator);

    try std.testing.expect(!plan.ok);
    try std.testing.expectEqual(FailureReason.missing_live_command, plan.reason.?);
    try std.testing.expect(std.mem.find(u8, plan.message.?, "No live command resolved") != null);
}

test "resolve live plan reports missing arguments" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"custom":{"live":"echo $zignite_args"}},"detect":{},"revision":83}
    , 83);

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/custom/main.txt",
        .filetype = "custom",
        .action = .live,
    });
    defer plan.deinit(allocator);

    try std.testing.expect(!plan.ok);
    try std.testing.expectEqual(FailureReason.missing_arguments, plan.reason.?);
    try std.testing.expect(std.mem.find(u8, plan.message.?, "requires additional arguments") != null);
    try std.testing.expect(plan.requires_arguments);
    try std.testing.expectEqualStrings("live", plan.resolved_command_name.?);
    try std.testing.expectEqualStrings("custom live args", plan.argument_prompt.?);
}

test "resolve last plan reports missing previous command" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"lastft":{"run":"echo run"}},"detect":{},"revision":84}
    , 84);

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/lastft/main.py",
        .filetype = "lastft",
        .action = .last,
    });
    defer plan.deinit(allocator);

    try std.testing.expect(!plan.ok);
    try std.testing.expectEqual(FailureReason.missing_last_command, plan.reason.?);
    try std.testing.expect(std.mem.find(u8, plan.message.?, "No previous build command") != null);
}

test "resolve last plan reports stale command" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"staleft":{"test":"pytest -q"}},"detect":{},"revision":85}
    , 85);
    try @import("action/state.zig").setLastCommand(std.testing.io, allocator, null, "staleft", "run");

    var plan = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/staleft/main.py",
        .filetype = "staleft",
        .action = .last,
    });
    defer plan.deinit(allocator);

    try std.testing.expect(!plan.ok);
    try std.testing.expectEqual(FailureReason.stale_last_command, plan.reason.?);
    try std.testing.expect(std.mem.find(u8, plan.message.?, "Command 'run' not found") != null);
}

test "resolve last plan reuses backend remembered command" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    defer @import("action/state.zig").resetForTests();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"rememberft":{"test":"pytest -q"}},"detect":{},"revision":86}
    , 86);

    var first = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/rememberft/main.py",
        .filetype = "rememberft",
        .action = .named,
        .command_name = "test",
    });
    defer first.deinit(allocator);

    var second = try resolvePlan(std.testing.io, allocator, null, .{
        .path = "/tmp/rememberft/main.py",
        .filetype = "rememberft",
        .action = .last,
    });
    defer second.deinit(allocator);

    try std.testing.expect(second.ok);
    try std.testing.expectEqualStrings("test", second.resolved_command_name.?);
    try std.testing.expectEqualStrings("pytest -q", second.exec_command.?);
}
