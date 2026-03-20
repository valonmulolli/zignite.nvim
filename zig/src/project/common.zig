const std = @import("std");

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const max_bytes = 4 * 1024 * 1024;
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

pub fn freeOwnedNameList(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}

pub fn pushUniqueName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    if (value.len == 0) return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try names.append(allocator, try allocator.dupe(u8, value));
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
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var prev_was_slash = false;
    for (value) |ch| {
        const mapped = if (ch == '\\') '/' else ch;
        if (mapped == '/') {
            if (prev_was_slash) continue;
            prev_was_slash = true;
        } else {
            prev_was_slash = false;
        }
        try normalized.append(allocator, mapped);
    }
    while (normalized.items.len > 1 and normalized.items[normalized.items.len - 1] == '/') {
        _ = normalized.pop();
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
