const std = @import("std");

pub fn stripAnsiAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
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
