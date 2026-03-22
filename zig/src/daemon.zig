const std = @import("std");
const detect = @import("detect.zig");
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
const QUICKFIX_RES_BEGIN = "@@ZQF_RES_BEGIN";
const QUICKFIX_RES_END = "@@ZQF_RES_END";
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
    var reader = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', QUICKFIX_MAX_LINE);
        if (maybe_line == null) break;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = stripTrailingCR(line_owned);
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

    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', QUICKFIX_MAX_LINE);
        if (maybe_line == null) return error.UnexpectedEof;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = stripTrailingCR(line_owned);

        if (isFrameEndLine(line, QUICKFIX_REQ_END, header.request_id)) break;

        const content = if (line.len > 0 and line[0] == '\t') line[1..] else line;
        try payload_writer.writeAll(content);
        try payload_writer.writeByte('\n');
    }

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    const out_writer = out_buf.writer(allocator);
    try quickfix.processQuickfixPayload(allocator, payload.items, header.options, false, out_writer);

    try stdout.print("{s} {d}\n", .{ QUICKFIX_RES_BEGIN, header.request_id });
    var split = std.mem.splitScalar(u8, out_buf.items, '\n');
    while (split.next()) |line| {
        if (line.len == 0) continue;
        try stdout.writeByte('\t');
        try stdout.writeAll(line);
        try stdout.writeByte('\n');
    }
    try stdout.print("{s} {d}\n", .{ QUICKFIX_RES_END, header.request_id });
}

fn handleDetectFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = try parseDetectBegin(begin_line);
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DETECT_MAX_LINE);
        if (maybe_line == null) return error.UnexpectedEof;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = stripTrailingCR(line_owned);
        if (isFrameEndLine(line, DETECT_REQ_END, header.request_id)) break;
    }

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

    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', PROJECT_MAX_LINE);
        if (maybe_line == null) return error.UnexpectedEof;
        const line_owned = maybe_line.?;
        defer allocator.free(line_owned);
        const line = stripTrailingCR(line_owned);

        if (isFrameEndLine(line, PROJECT_REQ_END, header.request_id)) break;

        if (line.len > 0 and line[0] == '\t') {
            try request_args.append(allocator, try allocator.dupe(u8, line[1..]));
        } else if (line.len > 0) {
            try request_args.append(allocator, try allocator.dupe(u8, line));
        }
    }

    try stdout.print("{s} {d}\n", .{ PROJECT_RES_BEGIN, header.request_id });
    const options = project.parseArgs(request_args.items);
    if (options) |parsed| {
        const contents = project.readProjectFile(allocator, parsed.path);
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

fn isFrameEndLine(line: []const u8, marker_name: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, marker_name)) return false;
    const raw_id = it.next() orelse return false;
    if (it.next() != null) return false;
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
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

test "isFrameEndLine validates marker and request id" {
    try std.testing.expect(isFrameEndLine("@@ZPRJ_REQ_END 19", PROJECT_REQ_END, 19));
    try std.testing.expect(!isFrameEndLine("@@ZPRJ_REQ_END 18", PROJECT_REQ_END, 19));
    try std.testing.expect(!isFrameEndLine("@@ZDET_REQ_END 19", PROJECT_REQ_END, 19));
}
