const std = @import("std");

pub fn readFileAllocWithIO(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const max_bytes = 4 * 1024 * 1024;
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn freeOwnedNameList(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}

pub fn deinitOwnedNameList(allocator: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |name| {
        allocator.free(name);
    }
    names.deinit(allocator);
}

pub fn hasControlChars(value: []const u8) bool {
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7F) return true;
    }
    return false;
}

/// Protocol delimiter prefixes used by the Zig daemon for frame markers.
/// Values containing these should not be embedded in legacy line-delimited
/// output, as they would be misinterpreted as protocol frame boundaries.
const protocol_delimiter_prefixes = [_][]const u8{
    "@@ZQF_",
    "@@ZBR_",
    "@@ZDET_",
    "@@ZPRJ_",
    "@@ZCFG_",
    "@@ZBA_",
    "@@ZRUN_",
};

/// Returns true if `value` contains a protocol delimiter prefix that could
/// be misinterpreted as a frame boundary in the line-delimited protocol.
pub fn hasProtocolMarkers(value: []const u8) bool {
    for (protocol_delimiter_prefixes) |prefix| {
        if (std.mem.find(u8, value, prefix) != null) return true;
    }
    return false;
}

/// Combined check: returns true when the value is unsafe to embed in a
/// legacy line-delimited payload. Checks both control characters and
/// protocol marker prefixes.
pub fn hasInvalidPayloadChars(value: []const u8) bool {
    return hasControlChars(value) or hasProtocolMarkers(value);
}

pub fn pushUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    if (value.len == 0) return;
    if (hasInvalidPayloadChars(value)) return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const owned_value = try allocator.dupe(u8, value);
    names.append(allocator, owned_value) catch |err| {
        allocator.free(owned_value);
        return err;
    };
}

pub fn trimSpaces(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

pub fn stripTrailingCR(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') {
        return text[0 .. text.len - 1];
    }
    return text;
}

pub fn normalizePathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return allocator.dupe(u8, "");

    const absolute = value[0] == '/' or value[0] == '\\';
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, value, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!absolute) {
                try parts.append(allocator, part);
            }
            continue;
        }
        try parts.append(allocator, part);
    }

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    if (absolute) try normalized.append(allocator, '/');
    for (parts.items, 0..) |part, index| {
        if (index > 0) try normalized.append(allocator, '/');
        try normalized.appendSlice(allocator, part);
    }
    if (normalized.items.len == 0) {
        try normalized.append(allocator, if (absolute) '/' else '.');
    }
    return try normalized.toOwnedSlice(allocator);
}

pub fn makeRelativeToRootAlloc(allocator: std.mem.Allocator, root: []const u8, filepath: []const u8) ![]u8 {
    if (root.len > 0 and std.mem.startsWith(u8, filepath, root)) {
        var start = root.len;
        if (filepath.len > start and filepath[start] == '/') {
            start += 1;
        } else if (filepath.len > start) {
            return try allocator.dupe(u8, std.fs.path.basename(filepath));
        }
        return try allocator.dupe(u8, filepath[start..]);
    }
    return try allocator.dupe(u8, std.fs.path.basename(filepath));
}

pub fn quoteShellArgAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);

    try quoted.ensureTotalCapacity(allocator, value.len + 2);
    quoted.appendAssumeCapacity('\'');
    var run_start: usize = 0;
    for (value, 0..) |ch, i| {
        if (ch != '\'') continue;
        if (i > run_start) quoted.appendSliceAssumeCapacity(value[run_start..i]);
        quoted.appendSliceAssumeCapacity("'\"'\"'");
        run_start = i + 1;
    }
    if (run_start < value.len) quoted.appendSliceAssumeCapacity(value[run_start..]);
    quoted.appendAssumeCapacity('\'');

    return try quoted.toOwnedSlice(allocator);
}

pub fn quoteShellArgIfNeededAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (isShellSafeArg(value)) {
        return try allocator.dupe(u8, value);
    }
    return try quoteShellArgAlloc(allocator, value);
}

fn isShellSafeArg(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        switch (ch) {
            '/', '.', '_', '-', ':', '+', '=', ',', '@' => continue,
            else => return false,
        }
    }
    return true;
}

test "quoteShellArgAlloc escapes embedded single quotes" {
    const allocator = std.testing.allocator;
    const quoted = try quoteShellArgAlloc(allocator, "cmd/app's");
    defer allocator.free(quoted);

    try std.testing.expectEqualStrings("'cmd/app'\"'\"'s'", quoted);
}

test "quoteShellArgIfNeededAlloc preserves safe args and quotes spaces" {
    const allocator = std.testing.allocator;

    const safe = try quoteShellArgIfNeededAlloc(allocator, "build-debug/bin");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("build-debug/bin", safe);

    const spaced = try quoteShellArgIfNeededAlloc(allocator, "build debug");
    defer allocator.free(spaced);
    try std.testing.expectEqualStrings("'build debug'", spaced);
}

test "normalizePathAlloc collapses separators and trims trailing slash" {
    const allocator = std.testing.allocator;
    const normalized = try normalizePathAlloc(allocator, "C:\\\\work//demo///src/");
    defer allocator.free(normalized);

    try std.testing.expectEqualStrings("C:/work/demo/src", normalized);
}

test "hasControlChars detects newline, tab, and DEL" {
    try std.testing.expect(!hasControlChars(""));
    try std.testing.expect(!hasControlChars("safe text 42"));
    try std.testing.expect(hasControlChars("line\nbreak"));
    try std.testing.expect(hasControlChars("tab\there"));
    try std.testing.expect(hasControlChars("delete\x7F"));
    try std.testing.expect(hasControlChars("\x01bell"));
}

test "hasProtocolMarkers detects all known zignite protocol prefixes" {
    try std.testing.expect(!hasProtocolMarkers(""));
    try std.testing.expect(!hasProtocolMarkers("safe path/file.txt"));
    try std.testing.expect(hasProtocolMarkers("/tmp/@@ZQF_BEGIN/file"));
    try std.testing.expect(hasProtocolMarkers("@@ZBR_END"));
    try std.testing.expect(hasProtocolMarkers("@@ZDET_RES_BEGIN 5"));
    try std.testing.expect(hasProtocolMarkers("/root/@@ZPRJ_REQ_BEGIN"));
    try std.testing.expect(hasProtocolMarkers("@@ZCFG_SYNC"));
    try std.testing.expect(hasProtocolMarkers("path/@@ZBA_RESULT/data"));
    try std.testing.expect(hasProtocolMarkers("@@ZRUN_REQ_END 42"));
}

test "hasProtocolMarkers false for similar but non-matching strings" {
    try std.testing.expect(!hasProtocolMarkers("@@ZOTHER_BEGIN"));
    try std.testing.expect(!hasProtocolMarkers("@@ZQG_"));
    try std.testing.expect(!hasProtocolMarkers("@ZQF_"));
    try std.testing.expect(!hasProtocolMarkers("just @@ random"));
}

test "hasInvalidPayloadChars combines control char and protocol marker checks" {
    try std.testing.expect(!hasInvalidPayloadChars(""));
    try std.testing.expect(!hasInvalidPayloadChars("safe path/main.zig"));
    try std.testing.expect(hasInvalidPayloadChars("bad\nfile"));
    try std.testing.expect(hasInvalidPayloadChars("@@ZQF_BEGIN"));
    try std.testing.expect(hasInvalidPayloadChars("/tmp/@@ZQF_END/file"));
    try std.testing.expect(hasInvalidPayloadChars("tab\t here"));
}

test "pushUniqueName deduplicates and rejects empty/control/protocol inputs" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer deinitOwnedNameList(allocator, &names);

    try pushUniqueName(allocator, &names, "BUILD");
    try pushUniqueName(allocator, &names, "BUILD");
    try pushUniqueName(allocator, &names, "TEST");
    try pushUniqueName(allocator, &names, "");
    try pushUniqueName(allocator, &names, "BAD\nNAME");
    try pushUniqueName(allocator, &names, "@@ZQF_BEGIN");
    try pushUniqueName(allocator, &names, "/tmp/@@ZBR_END/cmd");

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("BUILD", names.items[0]);
    try std.testing.expectEqualStrings("TEST", names.items[1]);
}

test "trimSpaces strips all four whitespace variants" {
    try std.testing.expectEqualStrings("hello", trimSpaces("  \t\r\nhello \t\r\n"));
    try std.testing.expectEqualStrings("", trimSpaces(""));
    try std.testing.expectEqualStrings("", trimSpaces(" \t\r\n"));
    try std.testing.expectEqualStrings("inner only", trimSpaces("inner only"));
}

test "stripTrailingCR removes only the final CR" {
    try std.testing.expectEqualStrings("hello", stripTrailingCR("hello\r"));
    try std.testing.expectEqualStrings("hello\rworld", stripTrailingCR("hello\rworld"));
    try std.testing.expectEqualStrings("", stripTrailingCR(""));
    try std.testing.expectEqualStrings("a", stripTrailingCR("a"));
}

test "makeRelativeToRootAlloc strips the root prefix and leading slash" {
    const allocator = std.testing.allocator;

    const in_root = try makeRelativeToRootAlloc(allocator, "/project", "/project/src/main.zig");
    defer allocator.free(in_root);
    try std.testing.expectEqualStrings("src/main.zig", in_root);

    const no_root = try makeRelativeToRootAlloc(allocator, "/elsewhere", "/project/main.zig");
    defer allocator.free(no_root);
    try std.testing.expectEqualStrings("main.zig", no_root);

    const empty_root = try makeRelativeToRootAlloc(allocator, "", "/project/main.zig");
    defer allocator.free(empty_root);
    try std.testing.expectEqualStrings("main.zig", empty_root);
}

test "quoteShellArgIfNeededAlloc quotes empty string" {
    const allocator = std.testing.allocator;
    const quoted = try quoteShellArgIfNeededAlloc(allocator, "");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("''", quoted);
}

test "quoteShellArgAlloc wraps simple arg without escaping" {
    const allocator = std.testing.allocator;
    const quoted = try quoteShellArgAlloc(allocator, "simple");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("'simple'", quoted);
}
