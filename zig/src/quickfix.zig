const std = @import("std");
const ansi = @import("quickfix/ansi.zig");
const diagnostic = @import("quickfix/diagnostic.zig");
const frame = @import("protocol/frame.zig");
const protocol_stdio = @import("protocol/stdio.zig");
const tail = @import("quickfix/tail.zig");
const types = @import("quickfix/types.zig");

pub const Options = types.Options;
pub const parseArgs = types.parseArgs;

const DaemonRequestHeader = struct {
    request_id: u64,
    options: Options,
};

const DAEMON_REQ_BEGIN = "@@ZQF_BEGIN";
const DAEMON_REQ_END = "@@ZQF_END";
const DAEMON_RES_BEGIN = "@@ZQF_RES_BEGIN";
const DAEMON_RES_ERR = "@@ZQF_RES_ERR";
const DAEMON_RES_END = "@@ZQF_RES_END";
const DAEMON_MAX_LINE = 1 * 1024 * 1024;

pub fn runMode(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const input = try readStdinAll(allocator, io);
    defer allocator.free(input);

    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();
    try processQuickfixPayload(allocator, input, options, false, stdout);
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
        const maybe_begin = try frame.readLineAlloc(allocator, reader, DAEMON_MAX_LINE);
        if (maybe_begin == null) break;

        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = frame.stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DAEMON_REQ_BEGIN)) continue;
        handleDaemonFrame(allocator, reader, stdout, begin_line) catch |err| {
            if (err == error.UnexpectedEof) break;
            return err;
        };
    }
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = parseDaemonBegin(begin_line) catch |err| {
        if (frame.parseRequestId(begin_line, DAEMON_REQ_BEGIN)) |request_id| {
            try writeDaemonResponse(stdout, request_id, "", err);
            try stdout.flush();
            return;
        }
        return err;
    };
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    var payload_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &payload);
    defer payload = payload_writer.toArrayList();
    const WritePayloadLine = struct {
        payload_writer: *std.Io.Writer.Allocating,

        fn onLine(self: @This(), line: []const u8) !void {
            const content = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            try self.payload_writer.writer.writeAll(content);
            try self.payload_writer.writer.writeByte('\n');
        }
    };
    const write_payload_line = WritePayloadLine{ .payload_writer = &payload_writer };
    var response_err: ?anyerror = null;
    const completed = blk: {
        const result = frame.readUntilEnd(
            allocator,
            reader,
            DAEMON_MAX_LINE,
            DAEMON_REQ_END,
            header.request_id,
            write_payload_line,
            WritePayloadLine.onLine,
        ) catch |err| {
            response_err = err;
            break :blk false;
        };
        break :blk result;
    };

    if (response_err == null and !completed) return error.UnexpectedEof;

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    var out_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &out_buf);
    defer out_buf = out_writer.toArrayList();
    if (response_err == null) {
        processQuickfixPayload(allocator, payload.items, header.options, false, &out_writer.writer) catch |err| {
            response_err = err;
        };
    }
    try writeDaemonResponse(stdout, header.request_id, out_buf.items, response_err);
    try stdout.flush();
}

pub fn processQuickfixPayload(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    already_truncated: bool,
    writer: anytype,
) !void {
    var tail_lines = try tail.collectTailLineViews(allocator, input, options.max_bytes);
    defer tail_lines.deinit(allocator);

    var start_idx = tail_lines.start_idx;
    const visible_count = tail_lines.items.len - start_idx;
    const overflow_lines = visible_count > options.max_lines;
    if (overflow_lines) {
        start_idx = tail_lines.items.len - options.max_lines;
    }
    const final_count = tail_lines.items.len - start_idx;
    const is_truncated = already_truncated or tail_lines.truncated or overflow_lines;

    if (is_truncated) {
        try writer.writeAll("[zignite] quickfix output truncated\n");
    }

    const strip_enabled = options.strip_ansi and options.strip_max_lines > 0;
    var strip_from_idx = tail_lines.items.len;
    if (strip_enabled) {
        strip_from_idx = if (options.strip_max_lines >= final_count)
            start_idx
        else
            tail_lines.items.len - options.strip_max_lines;
    }

    var i = start_idx;
    while (i < tail_lines.items.len) : (i += 1) {
        const original_line = tail_lines.items[i];
        var tmp_line: ?[]u8 = null;
        var line_view: []const u8 = original_line;

        if (strip_enabled and i >= strip_from_idx) {
            tmp_line = try ansi.stripAnsiAlloc(allocator, original_line);
            line_view = tmp_line.?;
        }

        const maybe_diag = if (options.parse_diagnostics) try diagnostic.canonicalizeDiagnostic(allocator, line_view) else null;
        if (maybe_diag) |diag| {
            try writer.writeAll(diag);
            try writer.writeByte('\n');
            allocator.free(diag);
        } else {
            try writer.writeAll(line_view);
            try writer.writeByte('\n');
        }

        if (tmp_line) |owned| allocator.free(owned);
    }
}

pub fn writeDaemonResponse(
    writer: anytype,
    request_id: u64,
    body: []const u8,
    response_err: ?anyerror,
) !void {
    try writer.print("{s} {d}\n", .{ DAEMON_RES_BEGIN, request_id });
    if (response_err) |err| {
        try writer.print("{s} {d} {s}\n", .{ DAEMON_RES_ERR, request_id, @errorName(err) });
    } else {
        var split = std.mem.splitScalar(u8, body, '\n');
        while (split.next()) |line| {
            if (line.len == 0) continue;
            try writer.writeByte('\t');
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }
    try writer.print("{s} {d}\n", .{ DAEMON_RES_END, request_id });
}

fn parseDaemonBegin(line: []const u8) !DaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDaemonHeader;
    if (!std.mem.eql(u8, marker, DAEMON_REQ_BEGIN)) return error.InvalidDaemonHeader;

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDaemonHeader, 10);
    const max_lines = try types.parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const max_bytes = try types.parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const strip_ansi = try types.parseBool(it.next() orelse return error.InvalidDaemonHeader);
    const strip_max_lines = try types.parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const parse_diagnostics = try types.parseBool(it.next() orelse return error.InvalidDaemonHeader);
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

fn readStdinAll(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var stdin_ctx: protocol_stdio.Stdin = .{};
    stdin_ctx.init(io);
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(allocator);
    try stdin_ctx.io().appendRemainingUnlimited(allocator, &input);
    return try input.toOwnedSlice(allocator);
}
test "quickfix max_bytes keeps newest lines" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try processQuickfixPayload(allocator, "first-line\nsecond-line\nnewest-line\n", .{
        .max_lines = 10,
        .max_bytes = 12,
        .strip_ansi = false,
        .strip_max_lines = 10,
        .parse_diagnostics = false,
    }, false, &out.writer);

    try std.testing.expectEqualStrings(
        "[zignite] quickfix output truncated\nnewest-line\n",
        out.written(),
    );
}

test "quickfix strips ansi and canonicalizes arrow diagnostics" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try processQuickfixPayload(
        allocator,
        "--> src/main.zig:12:4: unexpected token\n\x1b[31mplain error\x1b[0m\n",
        .{
            .max_lines = 10,
            .max_bytes = 1024,
            .strip_ansi = true,
            .strip_max_lines = 10,
            .parse_diagnostics = true,
        },
        false,
        &out.writer,
    );

    try std.testing.expectEqualStrings(
        "src/main.zig:12:4: unexpected token\nplain error\n",
        out.written(),
    );
}

test "quickfix canonicalizes paren diagnostics" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try processQuickfixPayload(
        allocator,
        "src/main.c(7:2) missing semicolon\n",
        .{
            .max_lines = 10,
            .max_bytes = 1024,
            .strip_ansi = false,
            .strip_max_lines = 10,
            .parse_diagnostics = true,
        },
        false,
        &out.writer,
    );

    try std.testing.expectEqualStrings(
        "src/main.c:7:2: missing semicolon\n",
        out.written(),
    );
}

test "quickfix daemon response emits error frame" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeDaemonResponse(&out.writer, 42, "", error.OutOfMemory);

    try std.testing.expectEqualStrings(
        "@@ZQF_RES_BEGIN 42\n@@ZQF_RES_ERR 42 OutOfMemory\n@@ZQF_RES_END 42\n",
        out.written(),
    );
}
