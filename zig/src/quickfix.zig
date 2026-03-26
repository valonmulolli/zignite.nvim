const std = @import("std");
const ansi = @import("quickfix/ansi.zig");
const diagnostic = @import("quickfix/diagnostic.zig");
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
const DAEMON_RES_END = "@@ZQF_RES_END";
const DAEMON_MAX_LINE = 16 * 1024 * 1024;

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    const input = try readStdinAll(allocator);
    defer allocator.free(input);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try processQuickfixPayload(allocator, input, options, false, stdout);
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
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DAEMON_MAX_LINE);
        if (maybe_begin == null) break;

        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DAEMON_REQ_BEGIN)) continue;

        const header = parseDaemonBegin(begin_line) catch continue;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(allocator);
        var payload_writer = payload.writer(allocator);
        var completed = false;

        while (true) {
            const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DAEMON_MAX_LINE);
            if (maybe_line == null) break;

            const line_owned = maybe_line.?;
            defer allocator.free(line_owned);
            const line = stripTrailingCR(line_owned);

            if (isDaemonEndLine(line, header.request_id)) {
                completed = true;
                break;
            }

            const content = if (line.len > 0 and line[0] == '\t') line[1..] else line;
            try payload_writer.writeAll(content);
            try payload_writer.writeByte('\n');
        }

        if (!completed) break;

        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(allocator);
        const out_writer = out_buf.writer(allocator);
        try processQuickfixPayload(allocator, payload.items, header.options, false, out_writer);

        try stdout.print("{s} {d}\n", .{ DAEMON_RES_BEGIN, header.request_id });
        var split = std.mem.splitScalar(u8, out_buf.items, '\n');
        while (split.next()) |line| {
            if (line.len == 0) continue;
            try stdout.writeByte('\t');
            try stdout.writeAll(line);
            try stdout.writeByte('\n');
        }
        try stdout.print("{s} {d}\n", .{ DAEMON_RES_END, header.request_id });
        try stdout.flush();
    }
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

fn isDaemonEndLine(line: []const u8, request_id: u64) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return false;
    if (!std.mem.eql(u8, marker, DAEMON_REQ_END)) return false;

    const raw_id = it.next() orelse return false;
    if (it.next() != null) return false;
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

fn readStdinAll(allocator: std.mem.Allocator) ![]u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    return try stdin_reader.interface.readAllAlloc(allocator, std.math.maxInt(usize));
}

fn stripTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

test "quickfix max_bytes keeps newest lines" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try processQuickfixPayload(allocator, "first-line\nsecond-line\nnewest-line\n", .{
        .max_lines = 10,
        .max_bytes = 12,
        .strip_ansi = false,
        .strip_max_lines = 10,
        .parse_diagnostics = false,
    }, false, out.writer(allocator));

    try std.testing.expectEqualStrings(
        "[zignite] quickfix output truncated\nnewest-line\n",
        out.items,
    );
}

test "quickfix strips ansi and canonicalizes arrow diagnostics" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

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
        out.writer(allocator),
    );

    try std.testing.expectEqualStrings(
        "src/main.zig:12:4: unexpected token\nplain error\n",
        out.items,
    );
}

test "quickfix canonicalizes paren diagnostics" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

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
        out.writer(allocator),
    );

    try std.testing.expectEqualStrings(
        "src/main.c:7:2: missing semicolon\n",
        out.items,
    );
}
