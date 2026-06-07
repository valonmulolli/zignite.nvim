const std = @import("std");
const parse = @import("detect/parse.zig");
const protocol_stdio = @import("protocol/stdio.zig");
const template = @import("detect/template.zig");
const types = @import("detect/types.zig");
const frame = @import("protocol/frame.zig");

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

pub fn runMode(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const commands = try detectToolCommandsWithIO(io, allocator, options.tool);
    defer freeOwnedCommandList(allocator, commands);

    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();
    for (commands) |command| {
        try stdout.print("{s}\n", .{command});
    }
    try stdout.flush();
}

pub fn runDaemon(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdin_ctx: protocol_stdio.Stdin = .{};
    stdin_ctx.init(io);
    const reader = stdin_ctx.io();
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();

    while (true) {
        const maybe_begin = try frame.readLineAlloc(allocator, reader, DETECT_DAEMON_MAX_LINE);
        if (maybe_begin == null) break;

        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = frame.stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DETECT_DAEMON_REQ_BEGIN)) continue;
        handleDaemonFrame(allocator, io, reader, stdout, begin_line) catch |err| {
            if (err == error.UnexpectedEof) break;
            return err;
        };
    }
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = parseDetectDaemonBegin(begin_line) catch |err| {
        if (frame.parseRequestId(begin_line, DETECT_DAEMON_REQ_BEGIN)) |request_id| {
            try frame.writeErrorResponse(
                stdout,
                DETECT_DAEMON_RES_BEGIN,
                DETECT_DAEMON_RES_ERR,
                DETECT_DAEMON_RES_END,
                request_id,
                @errorName(err),
            );
            try stdout.flush();
            return;
        }
        return err;
    };
    const completed = try frame.skipUntilEnd(
        allocator,
        reader,
        DETECT_DAEMON_MAX_LINE,
        DETECT_DAEMON_REQ_END,
        header.request_id,
    );

    if (!completed) return error.UnexpectedEof;

    try stdout.print("{s} {d}\n", .{ DETECT_DAEMON_RES_BEGIN, header.request_id });
    const detect_result = detectToolCommandsWithIO(io, allocator, header.tool);
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

pub fn detectToolCommandsWithIO(io: std.Io, allocator: std.mem.Allocator, tool: Tool) ![][]u8 {
    const output = parse.detectToolOutputWithIO(io, allocator, tool) catch |err| switch (err) {
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
    var begin = try frame.parseBeginFrame(line, DETECT_DAEMON_REQ_BEGIN, error.InvalidDetectDaemonHeader);
    const tool = try parseTool(begin.it.next() orelse return error.InvalidDetectDaemonHeader);
    if (begin.it.next() != null) return error.InvalidDetectDaemonHeader;

    return .{
        .request_id = begin.request_id,
        .tool = tool,
    };
}

const TestReader = frame.TestReader;

test "parseArgs returns tool when --tool= is provided" {
    const options = try parseArgs(&.{
        "--detect",
        "--tool=zig",
    });
    try std.testing.expectEqual(Tool.zig, options.tool);
}

test "parseArgs accepts all four tool variants" {
    try std.testing.expectEqual(Tool.zig, (try parseArgs(&.{ "--detect", "--tool=zig" })).tool);
    try std.testing.expectEqual(Tool.go, (try parseArgs(&.{ "--detect", "--tool=go" })).tool);
    try std.testing.expectEqual(Tool.cargo, (try parseArgs(&.{ "--detect", "--tool=cargo" })).tool);
    try std.testing.expectEqual(Tool.odin, (try parseArgs(&.{ "--detect", "--tool=odin" })).tool);
}

test "parseArgs rejects missing --tool" {
    try std.testing.expectError(error.MissingDetectTool, parseArgs(&.{"--detect"}));
    try std.testing.expectError(error.MissingDetectTool, parseArgs(&.{}));
}

test "parseArgs rejects unknown tools and unknown flags" {
    try std.testing.expectError(error.InvalidDetectTool, parseArgs(&.{ "--detect", "--tool=ruby" }));
    try std.testing.expectError(error.InvalidDetectTool, parseArgs(&.{ "--detect", "--tool=" }));
    try std.testing.expectError(error.InvalidDetectFlag, parseArgs(&.{ "--detect", "--bogus" }));
}

test "handleDaemonFrame writes detect error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{};
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDaemonFrame(
        allocator,
        std.testing.io,
        &reader,
        &out.writer,
        "@@ZDET_REQ_BEGIN 9 nope",
    );

    try std.testing.expectEqualStrings(
        "@@ZDET_RES_BEGIN 9\n@@ZDET_RES_ERR 9 InvalidDetectTool\n@@ZDET_RES_END 9\n",
        out.written(),
    );
}
