const std = @import("std");
const common = @import("../core/common.zig");

pub const UseEntry = struct {
    path: []u8,
    matched: bool,
};

pub fn freeOwnedUses(allocator: std.mem.Allocator, items: []UseEntry) void {
    for (items) |item| allocator.free(item.path);
    allocator.free(items);
}

pub fn parseUses(
    allocator: std.mem.Allocator,
    contents: []const u8,
    go_work_path: []const u8,
    match_path: ?[]const u8,
) ![]UseEntry {
    const workspace_dir = std.fs.path.dirname(go_work_path) orelse ".";
    var normalized_match_path: ?[]u8 = null;
    defer if (normalized_match_path) |value| allocator.free(value);
    if (match_path) |raw_match| {
        normalized_match_path = try common.normalizePathAlloc(allocator, raw_match);
    }

    var uses: std.ArrayList(UseEntry) = .empty;
    errdefer {
        for (uses.items) |item| allocator.free(item.path);
        uses.deinit(allocator);
    }

    var in_use_block = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(stripLineComment(common.stripTrailingCR(raw_line)));
        if (line.len == 0) continue;

        if (!in_use_block) {
            if (std.mem.eql(u8, line, "use(") or std.mem.eql(u8, line, "use (")) {
                in_use_block = true;
                continue;
            }
            if (std.mem.startsWith(u8, line, "use ")) {
                const value = common.trimSpaces(line["use ".len..]);
                if (value.len > 0) {
                    try appendUse(allocator, &uses, workspace_dir, value, normalized_match_path);
                }
            }
            continue;
        }

        if (std.mem.eql(u8, line, ")")) {
            in_use_block = false;
            continue;
        }

        try appendUse(allocator, &uses, workspace_dir, line, normalized_match_path);
    }

    keepDeepestMatch(uses.items);
    return try uses.toOwnedSlice(allocator);
}

fn keepDeepestMatch(uses: []UseEntry) void {
    var best_index: ?usize = null;
    for (uses, 0..) |item, index| {
        if (!item.matched) continue;
        if (best_index == null or item.path.len > uses[best_index.?].path.len) {
            best_index = index;
        }
    }
    for (uses, 0..) |*item, index| {
        item.matched = best_index != null and index == best_index.?;
    }
}

fn appendUse(
    allocator: std.mem.Allocator,
    uses: *std.ArrayList(UseEntry),
    workspace_dir: []const u8,
    raw_value: []const u8,
    normalized_match_path: ?[]const u8,
) !void {
    const value = stripQuotes(common.trimSpaces(raw_value));
    if (value.len == 0) return;

    const joined = if (std.fs.path.isAbsolute(value))
        try allocator.dupe(u8, value)
    else
        try std.fs.path.join(allocator, &.{ workspace_dir, value });
    defer allocator.free(joined);

    const normalized = try common.normalizePathAlloc(allocator, joined);
    const matched = if (normalized_match_path) |candidate|
        std.mem.eql(u8, candidate, normalized) or
            (candidate.len > normalized.len and
                std.mem.startsWith(u8, candidate, normalized) and
                candidate[normalized.len] == '/')
    else
        false;

    for (uses.items) |*item| {
        if (std.mem.eql(u8, item.path, normalized)) {
            item.matched = item.matched or matched;
            allocator.free(normalized);
            return;
        }
    }

    uses.append(allocator, .{
        .path = normalized,
        .matched = matched,
    }) catch |err| {
        allocator.free(normalized);
        return err;
    };
}

fn stripLineComment(line: []const u8) []const u8 {
    const idx = std.mem.find(u8, line, "//") orelse return line;
    return line[0..idx];
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'') or (first == '`' and last == '`')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

test "parse go work use entries" {
    const allocator = std.testing.allocator;
    const items = try parseUses(
        allocator,
        \\go 1.24.0
        \\
        \\use (
        \\    .
        \\    ./tools
        \\)
    ,
        "/tmp/work/go.work",
        "/tmp/work/tools/cmd/app/main.go",
    );
    defer freeOwnedUses(allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("/tmp/work", items[0].path);
    try std.testing.expectEqual(false, items[0].matched);
    try std.testing.expectEqualStrings("/tmp/work/tools", items[1].path);
    try std.testing.expectEqual(true, items[1].matched);
}
