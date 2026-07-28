const std = @import("std");
const config = @import("../../config.zig");
const common = @import("../../project/core/common.zig");
const system_command = @import("../../system_command.zig");
const types = @import("types.zig");

pub fn writeResolvedOutputJson(
    stdout: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: types.ResolvedRunner,
    filetype: []const u8,
) !void {
    var wrapped_argv: std.ArrayList([]u8) = .empty;
    defer system_command.deinitOwnedArgv(allocator, &wrapped_argv);
    if (resolved.command) |command_text| {
        wrapped_argv = try system_command.buildSystemArgvWithIO(io, allocator, command_text, resolved.argv.items, resolved.cleanup_command);
    }

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();

    const ok = resolved.command != null;
    const reason: ?[]const u8 = if (ok) null else "no_runner";
    const message = if (ok)
        null
    else
        try std.fmt.allocPrint(allocator, "Error: No runner configured for filetype: {s}", .{filetype});
    defer if (message) |value| allocator.free(value);

    const payload = RunResolvedJson{
        .ok = ok,
        .reason = reason,
        .message = message,
        .execution_path = resolved.execution_path,
        .command = resolved.command,
        .argv = resolved.argv.items,
        .system_argv = wrapped_argv.items,
        .source = resolved.source,
        .filetype = filetype,
        .cwd = resolved.cwd,
        .name = resolved.name,
        .config_revision = config.getSyncedRevision(),
    };
    try std.json.Stringify.value(payload, .{}, &json_out.writer);
    try stdout.print("RESULT_JSON\t{s}\n", .{json_out.written()});
}

pub fn writeResolvedOutputLegacy(
    stdout: anytype,
    resolved: types.ResolvedRunner,
    filetype: []const u8,
) !void {
    const ok = resolved.command != null;
    try stdout.print("OK\t{d}\n", .{if (ok) @as(u8, 1) else @as(u8, 0)});
    if (!ok) {
        try stdout.print("REASON\tno_runner\n", .{});
        try stdout.print("MESSAGE\tError: No runner configured for filetype: {s}\n", .{filetype});
    }
    if (resolved.command) |command| {
        if (!common.hasInvalidPayloadChars(command)) {
            try stdout.print("COMMAND\t{s}\n", .{command});
        }
    }
    if (resolved.execution_path) |execution_path| {
        if (!common.hasInvalidPayloadChars(execution_path)) {
            try stdout.print("EXECUTION_PATH\t{s}\n", .{execution_path});
        }
    }
    for (resolved.argv.items) |arg| {
        if (!common.hasInvalidPayloadChars(arg)) {
            try stdout.print("ARGV\t{s}\n", .{arg});
        }
    }
    try stdout.print("SOURCE\t{s}\n", .{resolved.source});
    try stdout.print("FILETYPE\t{s}\n", .{filetype});
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});
    if (resolved.cwd) |cwd| {
        if (!common.hasInvalidPayloadChars(cwd)) {
            try stdout.print("CWD\t{s}\n", .{cwd});
        }
    }
    if (resolved.name) |name| {
        if (!common.hasInvalidPayloadChars(name)) {
            try stdout.print("NAME\t{s}\n", .{name});
        }
    }
}

const RunResolvedJson = struct {
    ok: bool,
    reason: ?[]const u8,
    message: ?[]const u8,
    execution_path: ?[]const u8,
    command: ?[]const u8,
    argv: []const []u8,
    system_argv: []const []u8,
    source: []const u8,
    filetype: []const u8,
    cwd: ?[]const u8,
    name: ?[]const u8,
    config_revision: u64,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(self.ok);
        if (self.reason) |reason_value| {
            try jw.objectField("reason");
            try jw.write(reason_value);
        }
        if (self.message) |message_value| {
            try jw.objectField("message");
            try jw.write(message_value);
        }
        if (self.execution_path) |execution_path_value| {
            try jw.objectField("execution_path");
            try jw.write(execution_path_value);
        }
        if (self.command) |command_value| {
            try jw.objectField("command");
            try jw.write(command_value);
        }
        try jw.objectField("argv");
        try jw.write(self.argv);
        if (self.system_argv.len > 0) {
            try jw.objectField("system_argv");
            try jw.write(self.system_argv);
        }
        try jw.objectField("source");
        try jw.write(self.source);
        try jw.objectField("filetype");
        try jw.write(self.filetype);
        try jw.objectField("config_revision");
        try jw.write(self.config_revision);
        if (self.cwd) |cwd_value| {
            try jw.objectField("cwd");
            try jw.write(cwd_value);
        }
        if (self.name) |name_value| {
            try jw.objectField("name");
            try jw.write(name_value);
        }
        try jw.endObject();
    }
};

test "writeResolvedOutputJson includes execution_path" {
    const allocator = std.testing.allocator;

    var resolved = types.ResolvedRunner{
        .source = "filetype",
        .filetype = try allocator.dupe(u8, "zig"),
        .execution_path = try allocator.dupe(u8, "/tmp/example/main.zig"),
        .name = try allocator.dupe(u8, "zig"),
    };
    defer resolved.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutputJson(&out.writer, allocator, std.testing.io, resolved, "zig");

    try std.testing.expect(std.mem.find(u8, out.written(), "\"execution_path\":\"/tmp/example/main.zig\"") != null);
}

test "writeResolvedOutputJson includes no_runner failure metadata when command is missing" {
    const allocator = std.testing.allocator;

    var resolved = types.ResolvedRunner{
        .source = "filetype",
        .filetype = try allocator.dupe(u8, "go"),
        .name = try allocator.dupe(u8, "go"),
    };
    defer resolved.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutputJson(&out.writer, allocator, std.testing.io, resolved, "go");

    try std.testing.expect(std.mem.find(u8, out.written(), "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"reason\":\"no_runner\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"message\":\"Error: No runner configured for filetype: go\"") != null);
}
