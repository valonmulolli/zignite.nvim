const std = @import("std");
const detect = @import("detect.zig");
const frame = @import("protocol/frame.zig");
const protocol_stdio = @import("protocol/stdio.zig");
const project = @import("project.zig");
const quickfix = @import("quickfix.zig");

const DETECT_REQ_BEGIN = "@@ZDET_REQ_BEGIN";
const DETECT_REQ_END = "@@ZDET_REQ_END";
const DETECT_RES_BEGIN = "@@ZDET_RES_BEGIN";
const DETECT_RES_END = "@@ZDET_RES_END";
const DETECT_RES_ERR = "@@ZDET_RES_ERR";
const DETECT_MAX_LINE = 4096;

const PROJECT_REQ_BEGIN = "@@ZPRJ_REQ_BEGIN";
const PROJECT_REQ_END = "@@ZPRJ_REQ_END";
const PROJECT_RES_BEGIN = "@@ZPRJ_RES_BEGIN";
const PROJECT_RES_END = "@@ZPRJ_RES_END";
const PROJECT_RES_ERR = "@@ZPRJ_RES_ERR";
const PROJECT_MAX_LINE = 16384;

const QUICKFIX_REQ_BEGIN = "@@ZQF_BEGIN";
const QUICKFIX_REQ_END = "@@ZQF_END";
const QUICKFIX_MAX_LINE = 16 * 1024 * 1024;

const QuickfixHeader = struct {
    request_id: u64,
    options: quickfix.Options,
};

const DetectHeader = struct {
    request_id: u64,
    tool: detect.Tool,
};

const ProjectHeader = struct {
    request_id: u64,
};

pub fn run(allocator: std.mem.Allocator) !void {
    var stdin_ctx: protocol_stdio.Stdin = .{};
    stdin_ctx.init();
    const reader = stdin_ctx.io();
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init();
    const stdout = stdout_ctx.io();

    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', QUICKFIX_MAX_LINE);
        if (maybe_line == null) break;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = frame.stripTrailingCR(line_owned);
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, QUICKFIX_REQ_BEGIN)) {
            try handleQuickfixFrame(allocator, reader, stdout, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, DETECT_REQ_BEGIN)) {
            try handleDetectFrame(allocator, reader, stdout, line);
            continue;
        }
        if (std.mem.startsWith(u8, line, PROJECT_REQ_BEGIN)) {
            try handleProjectFrame(allocator, reader, stdout, line);
            continue;
        }
    }
}

fn handleQuickfixFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = try parseQuickfixBegin(begin_line);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    var payload_writer = payload.writer(allocator);

    const WritePayloadLine = struct {
        payload_writer: *@TypeOf(payload.writer(allocator)),

        fn onLine(self: @This(), line: []const u8) !void {
            const content = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            try self.payload_writer.writeAll(content);
            try self.payload_writer.writeByte('\n');
        }
    };
    const write_payload_line = WritePayloadLine{ .payload_writer = &payload_writer };
    var response_err: ?anyerror = null;
    const completed = blk: {
        const result = frame.readUntilEnd(
            allocator,
            reader,
            QUICKFIX_MAX_LINE,
            QUICKFIX_REQ_END,
            header.request_id,
            write_payload_line.onLine,
        ) catch |err| {
            response_err = err;
            break :blk false;
        };
        break :blk result;
    };
    if (response_err == null and !completed) return error.UnexpectedEof;

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    const out_writer = out_buf.writer(allocator);
    if (response_err == null) {
        quickfix.processQuickfixPayload(allocator, payload.items, header.options, false, out_writer) catch |err| {
            response_err = err;
        };
    }
    try quickfix.writeDaemonResponse(stdout, header.request_id, out_buf.items, response_err);
    try stdout.flush();
}

fn handleDetectFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = try parseDetectBegin(begin_line);
    const completed = try frame.skipUntilEnd(
        allocator,
        reader,
        DETECT_MAX_LINE,
        DETECT_REQ_END,
        header.request_id,
    );
    if (!completed) return error.UnexpectedEof;

    try stdout.print("{s} {d}\n", .{ DETECT_RES_BEGIN, header.request_id });
    const detect_result = detect.detectToolCommands(allocator, header.tool);
    if (detect_result) |commands| {
        defer detect.freeOwnedCommandList(allocator, commands);
        for (commands) |command| {
            try stdout.writeByte('\t');
            try stdout.writeAll(command);
            try stdout.writeByte('\n');
        }
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ DETECT_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ DETECT_RES_END, header.request_id });
    try stdout.flush();
}

fn handleProjectFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = try parseProjectBegin(begin_line);
    var request_args: std.ArrayList([]u8) = .empty;
    defer {
        for (request_args.items) |arg| allocator.free(arg);
        request_args.deinit(allocator);
    }

    const ParseArgsLine = struct {
        allocator: std.mem.Allocator,
        request_args: *std.ArrayList([]u8),

        fn onLine(self: @This(), line: []const u8) !void {
            if (line.len > 0 and line[0] == '\t') {
                try self.request_args.append(self.allocator, try self.allocator.dupe(u8, line[1..]));
            } else if (line.len > 0) {
                try self.request_args.append(self.allocator, try self.allocator.dupe(u8, line));
            }
        }
    };
    const parse_args_line = ParseArgsLine{
        .allocator = allocator,
        .request_args = &request_args,
    };
    const completed = try frame.readUntilEnd(
        allocator,
        reader,
        PROJECT_MAX_LINE,
        PROJECT_REQ_END,
        header.request_id,
        parse_args_line.onLine,
    );
    if (!completed) return error.UnexpectedEof;

    try stdout.print("{s} {d}\n", .{ PROJECT_RES_BEGIN, header.request_id });
    const options = project.parseArgs(request_args.items);
    if (options) |parsed| {
        const contents = project.readProjectFile(allocator, parsed.kind, parsed.path);
        if (contents) |payload| {
            defer allocator.free(payload);
            project.writeOutput(stdout, allocator, parsed, payload) catch |err| {
                try stdout.print("{s} {d} {s}\n", .{ PROJECT_RES_ERR, header.request_id, @errorName(err) });
            };
        } else |err| {
            try stdout.print("{s} {d} {s}\n", .{ PROJECT_RES_ERR, header.request_id, @errorName(err) });
        }
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ PROJECT_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ PROJECT_RES_END, header.request_id });
    try stdout.flush();
}

fn parseQuickfixBegin(line: []const u8) !QuickfixHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDaemonHeader;
    if (!std.mem.eql(u8, marker, QUICKFIX_REQ_BEGIN)) return error.InvalidDaemonHeader;

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDaemonHeader, 10);
    const max_lines = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const max_bytes = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const strip_ansi = try parseBool(it.next() orelse return error.InvalidDaemonHeader);
    const strip_max_lines = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const parse_diagnostics = try parseBool(it.next() orelse return error.InvalidDaemonHeader);
    if (it.next() != null) return error.InvalidDaemonHeader;

    return .{
        .request_id = request_id,
        .options = .{
            .max_lines = max_lines,
            .max_bytes = max_bytes,
            .strip_ansi = strip_ansi,
            .strip_max_lines = strip_max_lines,
            .parse_diagnostics = parse_diagnostics,
        },
    };
}

fn parseDetectBegin(line: []const u8) !DetectHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDetectDaemonHeader;
    if (!std.mem.eql(u8, marker, DETECT_REQ_BEGIN)) return error.InvalidDetectDaemonHeader;

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDetectDaemonHeader, 10);
    const tool = try detect.parseTool(it.next() orelse return error.InvalidDetectDaemonHeader);
    if (it.next() != null) return error.InvalidDetectDaemonHeader;
    return .{ .request_id = request_id, .tool = tool };
}

fn parseProjectBegin(line: []const u8) !ProjectHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidProjectDaemonHeader;
    if (!std.mem.eql(u8, marker, PROJECT_REQ_BEGIN)) return error.InvalidProjectDaemonHeader;

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidProjectDaemonHeader, 10);
    if (it.next() != null) return error.InvalidProjectDaemonHeader;
    return .{ .request_id = request_id };
}

fn parseNonZeroInt(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    return if (parsed == 0) 1 else parsed;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) return false;
    return error.InvalidBoolean;
}

test "parseQuickfixBegin decodes request header" {
    const header = try parseQuickfixBegin("@@ZQF_BEGIN 42 100 2048 1 50 0");

    try std.testing.expectEqual(@as(u64, 42), header.request_id);
    try std.testing.expectEqual(@as(usize, 100), header.options.max_lines);
    try std.testing.expectEqual(@as(usize, 2048), header.options.max_bytes);
    try std.testing.expectEqual(true, header.options.strip_ansi);
    try std.testing.expectEqual(@as(usize, 50), header.options.strip_max_lines);
    try std.testing.expectEqual(false, header.options.parse_diagnostics);
}

test "parseDetectBegin decodes detect request header" {
    const header = try parseDetectBegin("@@ZDET_REQ_BEGIN 7 cargo");

    try std.testing.expectEqual(@as(u64, 7), header.request_id);
    try std.testing.expectEqual(detect.Tool.cargo, header.tool);
}

test "parseProjectBegin decodes project request header" {
    const header = try parseProjectBegin("@@ZPRJ_REQ_BEGIN 19");

    try std.testing.expectEqual(@as(u64, 19), header.request_id);
}
