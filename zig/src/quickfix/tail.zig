const std = @import("std");

pub const TailLineViews = struct {
    items: [][]const u8,
    start_idx: usize,
    truncated: bool,

    pub fn deinit(self: *TailLineViews, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

/// Strips a trailing carriage return from a line, if present.
fn stripCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

/// Drops lines from the front of `items` until `total_bytes` <= `max_bytes`,
/// with the invariant that at least one line always remains.
///
/// Returns `true` if any content was truncated (either dropped or a lone
/// oversized line was pinned).
fn trimToBudget(
    items: [][]const u8,
    start_idx: *usize,
    total_bytes: *usize,
    max_bytes: usize,
) bool {
    var truncated = false;
    while (total_bytes.* > max_bytes and start_idx.* + 1 < items.len) {
        total_bytes.* -= items[start_idx.*].len + 1;
        start_idx.* += 1;
        truncated = true;
    }
    if (total_bytes.* > max_bytes) {
        truncated = true;
    }
    return truncated;
}

pub fn collectTailLineViews(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_bytes: usize,
) !TailLineViews {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var total_bytes: usize = 0;
    var start_idx: usize = 0;
    var truncated = false;
    var line_start: usize = 0;

    for (input, 0..) |ch, i| {
        if (ch != '\n') continue;

        const line = stripCR(input[line_start..i]);
        line_start = i + 1;

        // Only non-empty lines are added to the output.
        // Empty lines (after CR stripping) contribute no visible content and
        // consume no budget — they are silently dropped.
        if (line.len == 0) continue;

        try lines.append(allocator, line);
        total_bytes += line.len + 1; // +1 for the '\n' delimiter

        if (trimToBudget(lines.items, &start_idx, &total_bytes, max_bytes)) {
            truncated = true;
        }
    }

    // Handle trailing content that has no closing newline.
    if (line_start < input.len) {
        const tail = stripCR(input[line_start..]);
        if (tail.len > 0) {
            try lines.append(allocator, tail);
            total_bytes += tail.len + 1;

            if (trimToBudget(lines.items, &start_idx, &total_bytes, max_bytes)) {
                truncated = true;
            }
        }
    }

    // If the input contained content but every line was empty after CR
    // stripping, we still flag truncated — there was nothing to show.
    if (lines.items.len == 0 and input.len > 0) {
        truncated = true;
    }

    return .{
        .items = try lines.toOwnedSlice(allocator),
        .start_idx = start_idx,
        .truncated = truncated,
    };
}

test "collectTailLineViews handles empty input" {
    const allocator = std.testing.allocator;
    var result = try collectTailLineViews(allocator, "", 100);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.start_idx);
    try std.testing.expect(!result.truncated);
}

test "collectTailLineViews handles input with only empty lines" {
    const allocator = std.testing.allocator;
    var result = try collectTailLineViews(allocator, "\n\n\n", 100);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
    try std.testing.expect(result.truncated);
}

test "collectTailLineViews skips empty lines but counts bytes" {
    const allocator = std.testing.allocator;
    var result = try collectTailLineViews(allocator, "a\n\nb\n", 100);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("a", result.items[0]);
    try std.testing.expectEqualStrings("b", result.items[1]);
    try std.testing.expect(!result.truncated);
}

test "collectTailLineViews strips trailing CR" {
    const allocator = std.testing.allocator;
    var result = try collectTailLineViews(allocator, "a\r\nb\r\n", 100);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("a", result.items[0]);
    try std.testing.expectEqualStrings("b", result.items[1]);
}

test "collectTailLineViews truncates by max_bytes" {
    const allocator = std.testing.allocator;
    var result = try collectTailLineViews(allocator, "aaaa\nbbbb\ncccc\ndddd\n", 10);
    defer result.deinit(allocator);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.start_idx > 0);
}

test "collectTailLineViews keeps tail line without newline" {
    const allocator = std.testing.allocator;
    var result = try collectTailLineViews(allocator, "a\nb\nc", 100);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    try std.testing.expectEqualStrings("c", result.items[2]);
}
