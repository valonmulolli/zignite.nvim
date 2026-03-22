const std = @import("std");

pub const Options = struct {
    max_lines: usize = 1000,
    max_bytes: usize = 262_144,
    strip_ansi: bool = true,
    strip_max_lines: usize = 400,
    parse_diagnostics: bool = true,
};

const DaemonRequestHeader = struct {
    request_id: u64,
    options: Options,
};

const DAEMON_REQ_BEGIN = "@@ZQF_BEGIN";
const DAEMON_REQ_END = "@@ZQF_END";
const DAEMON_RES_BEGIN = "@@ZQF_RES_BEGIN";
const DAEMON_RES_END = "@@ZQF_RES_END";
const DAEMON_MAX_LINE = 16 * 1024 * 1024;

const TailLineViews = struct {
    items: [][]const u8,
    start_idx: usize,
    truncated: bool,

    fn deinit(self: *TailLineViews, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--quickfix")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--max-lines=")) {
            options.max_lines = try parseNonZeroInt(arg["--max-lines=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--max-bytes=")) {
            options.max_bytes = try parseNonZeroInt(arg["--max-bytes=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--strip-ansi=")) {
            options.strip_ansi = try parseBool(arg["--strip-ansi=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--strip-max-lines=")) {
            options.strip_max_lines = try parseNonZeroInt(arg["--strip-max-lines=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--parse-diagnostics=")) {
            options.parse_diagnostics = try parseBool(arg["--parse-diagnostics=".len..]);
        } else {
            return error.InvalidQuickfixFlag;
        }
    }

    return options;
}

pub fn runMode(allocator: std.mem.Allocator, options: Options) !void {
    const input = try readStdinAll(allocator);
    defer allocator.free(input);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try processQuickfixPayload(allocator, input, options, false, stdout);
}

pub fn runDaemon(allocator: std.mem.Allocator) !void {
    var reader = std.fs.File.stdin().deprecatedReader();
    var stdout = std.fs.File.stdout().deprecatedWriter();

    while (true) {
        const maybe_begin = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DAEMON_MAX_LINE);
        if (maybe_begin == null) {
            break;
        }
        const begin_owned = maybe_begin.?;
        defer allocator.free(begin_owned);
        const begin_line = stripTrailingCR(begin_owned);

        if (!std.mem.startsWith(u8, begin_line, DAEMON_REQ_BEGIN)) {
            continue;
        }

        const header = parseDaemonBegin(begin_line) catch continue;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(allocator);
        var payload_writer = payload.writer(allocator);
        var completed = false;

        while (true) {
            const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', DAEMON_MAX_LINE);
            if (maybe_line == null) {
                break;
            }
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

        if (!completed) {
            break;
        }

        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(allocator);
        const out_writer = out_buf.writer(allocator);
        try processQuickfixPayload(allocator, payload.items, header.options, false, out_writer);

        try stdout.print("{s} {d}\n", .{ DAEMON_RES_BEGIN, header.request_id });
        var split = std.mem.splitScalar(u8, out_buf.items, '\n');
        while (split.next()) |line| {
            if (line.len == 0) {
                continue;
            }
            try stdout.writeByte('\t');
            try stdout.writeAll(line);
            try stdout.writeByte('\n');
        }
        try stdout.print("{s} {d}\n", .{ DAEMON_RES_END, header.request_id });
    }
}

pub fn processQuickfixPayload(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    already_truncated: bool,
    writer: anytype,
) !void {
    var tail_lines = try collectTailLineViews(allocator, input, options.max_bytes);
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
            tmp_line = try stripAnsiAlloc(allocator, original_line);
            line_view = tmp_line.?;
        }

        const maybe_diag = if (options.parse_diagnostics) try canonicalizeDiagnostic(allocator, line_view) else null;
        if (maybe_diag) |diag| {
            try writer.writeAll(diag);
            try writer.writeByte('\n');
            allocator.free(diag);
        } else {
            try writer.writeAll(line_view);
            try writer.writeByte('\n');
        }

        if (tmp_line) |owned| {
            allocator.free(owned);
        }
    }
}

fn parseDaemonBegin(line: []const u8) !DaemonRequestHeader {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const marker = it.next() orelse return error.InvalidDaemonHeader;
    if (!std.mem.eql(u8, marker, DAEMON_REQ_BEGIN)) {
        return error.InvalidDaemonHeader;
    }

    const request_id = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidDaemonHeader, 10);
    const max_lines = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const max_bytes = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const strip_ansi = try parseBool(it.next() orelse return error.InvalidDaemonHeader);
    const strip_max_lines = try parseNonZeroInt(it.next() orelse return error.InvalidDaemonHeader);
    const parse_diagnostics = try parseBool(it.next() orelse return error.InvalidDaemonHeader);
    if (it.next() != null) {
        return error.InvalidDaemonHeader;
    }

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
    if (!std.mem.eql(u8, marker, DAEMON_REQ_END)) {
        return false;
    }

    const raw_id = it.next() orelse return false;
    if (it.next() != null) {
        return false;
    }
    const parsed = std.fmt.parseInt(u64, raw_id, 10) catch return false;
    return parsed == request_id;
}

fn parseNonZeroInt(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    return if (parsed == 0) 1 else parsed;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) {
        return true;
    }
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) {
        return false;
    }
    return error.InvalidBoolean;
}

fn readStdinAll(allocator: std.mem.Allocator) ![]u8 {
    return try std.fs.File.stdin().deprecatedReader().readAllAlloc(allocator, std.math.maxInt(usize));
}

fn collectTailLineViews(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_bytes: usize,
) !TailLineViews {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var total_bytes: usize = 0;
    var start_idx: usize = 0;
    var truncated = false;

    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '\n') {
            continue;
        }

        var line = input[start..i];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        if (line.len > 0) {
            try lines.append(allocator, line);
            total_bytes += line.len + 1;
            while (total_bytes > max_bytes and start_idx + 1 < lines.items.len) {
                total_bytes -= lines.items[start_idx].len + 1;
                start_idx += 1;
                truncated = true;
            }
            if (total_bytes > max_bytes) {
                truncated = true;
            }
        }
        start = i + 1;
    }

    if (start < input.len) {
        var tail = input[start..];
        if (tail.len > 0 and tail[tail.len - 1] == '\r') {
            tail = tail[0 .. tail.len - 1];
        }
        if (tail.len > 0) {
            try lines.append(allocator, tail);
            total_bytes += tail.len + 1;
            while (total_bytes > max_bytes and start_idx + 1 < lines.items.len) {
                total_bytes -= lines.items[start_idx].len + 1;
                start_idx += 1;
                truncated = true;
            }
            if (total_bytes > max_bytes) {
                truncated = true;
            }
        }
    }

    return .{
        .items = try lines.toOwnedSlice(allocator),
        .start_idx = start_idx,
        .truncated = truncated,
    };
}

fn stripAnsiAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len) : (i += 1) {
                const ch = line[i];
                if (ch >= 0x40 and ch <= 0x7e) {
                    i += 1;
                    break;
                }
            }
            continue;
        }

        try out.append(allocator, line[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn canonicalizeDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var trimmed = trimSpaces(line);
    if (trimmed.len == 0) {
        return null;
    }

    if (std.mem.startsWith(u8, trimmed, "-->")) {
        trimmed = trimSpaces(trimmed[3..]);
    }

    if (try parseParenDiagnostic(allocator, trimmed)) |diag| {
        return diag;
    }
    if (try parseColonDiagnostic(allocator, trimmed)) |diag| {
        return diag;
    }

    return null;
}

fn parseColonDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') {
            continue;
        }

        const line_start = i + 1;
        var j = line_start;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        if (j == line_start or j >= line.len or line[j] != ':') {
            continue;
        }

        const line_no = std.fmt.parseInt(usize, line[line_start..j], 10) catch continue;
        const path = trimSpaces(line[0..i]);
        if (path.len == 0 or std.mem.indexOfAny(u8, path, "/\\.") == null) {
            continue;
        }

        const after_line = j + 1;
        var k = after_line;
        while (k < line.len and std.ascii.isDigit(line[k])) : (k += 1) {}

        var col_no: usize = 1;
        var msg_start = after_line;
        if (k > after_line and k < line.len and line[k] == ':') {
            col_no = std.fmt.parseInt(usize, line[after_line..k], 10) catch 1;
            msg_start = k + 1;
        }

        const msg = trimSpaces(line[msg_start..]);
        const normalized_msg = if (msg.len == 0) "diagnostic" else msg;
        return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ path, line_no, col_no, normalized_msg });
    }
    return null;
}

fn parseParenDiagnostic(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const colon_idx = std.mem.indexOfScalarPos(u8, line, open_idx + 1, ':') orelse return null;
    const close_idx = std.mem.indexOfScalarPos(u8, line, colon_idx + 1, ')') orelse return null;

    const path = trimSpaces(line[0..open_idx]);
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "/\\.") == null) {
        return null;
    }

    const line_no = std.fmt.parseInt(usize, line[open_idx + 1 .. colon_idx], 10) catch return null;
    const col_no = std.fmt.parseInt(usize, line[colon_idx + 1 .. close_idx], 10) catch return null;
    const msg = trimSpaces(line[close_idx + 1 ..]);
    const normalized_msg = if (msg.len == 0) "diagnostic" else msg;

    return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ path, line_no, col_no, normalized_msg });
}

fn trimSpaces(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and std.ascii.isWhitespace(input[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
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
