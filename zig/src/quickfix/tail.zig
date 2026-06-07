const std = @import("std");

pub const TailLineViews = struct {
    items: [][]const u8,
    start_idx: usize,
    truncated: bool,

    pub fn deinit(self: *TailLineViews, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

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

    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '\n') continue;

        var line = input[start..i];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        if (line.len > 0) {
            try lines.append(allocator, line);
        }
        total_bytes += line.len + 1;
        if (lines.items.len > 0) {
            while (total_bytes > max_bytes and start_idx + 1 < lines.items.len) {
                total_bytes -= lines.items[start_idx].len + 1;
                start_idx += 1;
                truncated = true;
            }
            if (total_bytes > max_bytes) truncated = true;
        } else {
            truncated = true;
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
            if (total_bytes > max_bytes) truncated = true;
        }
    }

    return .{
        .items = try lines.toOwnedSlice(allocator),
        .start_idx = start_idx,
        .truncated = truncated,
    };
}
