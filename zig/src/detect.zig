const std = @import("std");
const parse = @import("detect/parse.zig");
const template = @import("detect/template.zig");
const types = @import("detect/types.zig");

pub const Tool = types.Tool;
pub const Options = types.Options;
pub const parseTool = types.parseTool;
pub const freeOwnedCommandList = types.freeOwnedCommandList;

const DetectDaemonRequestHeader = struct {
    request_id: u64,
    tool: Tool,
};

const DETECT_DAEMON_REQ_BEGIN = "@@ZDET_REQ_BEGIN";
const DETECT_DAEMON_REQ_END = "@@ZDET_REQ_END";
const DETECT_DAEMON_RES_BEGIN = "@@ZDET_RES_BEGIN";
const DETECT_DAEMON_RES_END = "@@ZDET_RES_END";
const DETECT_DAEMON_RES_ERR = "@@ZDET_RES_ERR";
const DETECT_DAEMON_MAX_LINE = 4096;

pub fn parseArgs(args: []const []const u8) !Options {
    var tool: ?Tool = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--detect")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--tool=")) {
            tool = try parseTool(arg["--tool=".len..]);
        } else {
            return error.InvalidDetectFlag;
        }
    }

    return .{
        .tool = tool orelse return error.MissingDetectTool,
    };
}

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    const commands = try detectToolCommands(allocator, options.tool);
    defer freeOwnedCommandList(allocator, commands);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (commands) |command| {
        try stdout.print("{s}\n", .{command});
    }
    try stdout.flush();
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const reader = &stdin_reader.interface;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DETECT_DAEMON_MAX_LINE);
        if (maybe_begin == null) break;

        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = parse.stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DETECT_DAEMON_REQ_BEGIN)) continue;

        const header = parseDetectDaemonBegin(begin_line) catch continue;
        var completed = false;

        while (true) {
            const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DETECT_DAEMON_MAX_LINE);
            if (maybe_line == null) break;

            const line_owned = maybe_line.?;
            defer allocator.free(line_owned);
            const line = parse.stripTrailingCR(line_owned);

            if (isDetectDaemonEndLine(line, header.request_id)) {
                completed = true;
                break;
            }
        }

        if (!completed) break;

        try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_BEGIN, header.request_id });
        const detect_result = detectToolCommands(allocator, header.tool);
        if (detect_result) |commands| {
            defer freeOwnedCommandList(allocator, commands);
            for (commands) |command| {
                try stdout.writeByte('\t');
                try stdout.writeAll(command);
                try stdout.writeByte('\n');
            }
        } else |err| {
            try stdout.print("{s} {d} {s}\n", .{ DETECT_DAEMON_RES_ERR, header.request_id, @errorName(err) });
        }
        try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_END, header.request_id });
        try stdout.flush();
    }
}

pub fn detectToolCommands(allocator: std.mem.Allocator, tool: Tool) ![][]u8 {
    const output = parse.detectToolOutput(allocator, tool) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]u8, 0),
        else => return err,
    };
    defer allocator.free(output);

    return try detectToolCommandsFromOutput(allocator, tool, output);
}

fn detectToolCommandsFromOutput(allocator: std.mem.Allocator, tool: Tool, output: []const u8) ![][]u8 {
    const names = try parse.parseDetectCommandNames(allocator, tool, output);
    defer freeOwnedCommandList(allocator, names);
    return try template.buildDetectCommandRecords(allocator, tool, names);
}

fn parseDetectDaemonBegin(line: []const u8) !DetectDaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDetectDaemonHeader;
    if (!std.mem.eql(u8, marker, DETECT_DAEMON_REQ_BEGIN)) {
        return error.InvalidDetectDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDetectDaemonHeader, 10);
    const tool = try parseTool(it.next() orelse return error.InvalidDetectDaemonHeader);
    if (it.next() != null) {
        return error.InvalidDetectDaemonHeader;
    }

    return .{
        .request_id = request_id,
        .tool = tool,
    };
}

fn isDetectDaemonEndLine(line: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, DETECT_DAEMON_REQ_END)) {
        return false;
    }

    const raw_id = it.next() orelse return false;
    if (it.next() != null) {
        return false;
    }
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}
