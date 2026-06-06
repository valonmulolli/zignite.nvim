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

pub fn pushUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    if (value.len == 0) return;
    if (hasControlChars(value)) return;
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
        }
        return try allocator.dupe(u8, filepath[start..]);
    }
    return try allocator.dupe(u8, std.fs.path.basename(filepath));
}

pub fn quoteShellArgAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);

    try quoted.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try quoted.appendSlice(allocator, "'\"'\"'");
        } else {
            try quoted.append(allocator, ch);
        }
    }
    try quoted.append(allocator, '\'');

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
