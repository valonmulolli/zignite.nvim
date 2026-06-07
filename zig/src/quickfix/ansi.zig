const std = @import("std");

pub fn stripAnsiAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len) {
            const next = line[i + 1];
            if (next == '[') {
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
            if (next == ']') {
                i += 2;
                while (i < line.len) : (i += 1) {
                    const ch = line[i];
                    if (ch == 0x07) {
                        i += 1;
                        break;
                    }
                    if (ch == 0x1b and i + 1 < line.len and line[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
        }

        try out.append(allocator, line[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

test "stripAnsiAlloc passes through plain text" {
    const allocator = std.testing.allocator;
    const out = try stripAnsiAlloc(allocator, "hello world");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "stripAnsiAlloc strips CSI sequences" {
    const allocator = std.testing.allocator;
    const out = try stripAnsiAlloc(allocator, "\x1b[31mred\x1b[0m normal");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("red normal", out);
}

test "stripAnsiAlloc strips OSC sequences terminated by BEL" {
    const allocator = std.testing.allocator;
    const out = try stripAnsiAlloc(allocator, "before\x1b]0;title\x07after");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("beforeafter", out);
}

test "stripAnsiAlloc strips OSC sequences terminated by ST" {
    const allocator = std.testing.allocator;
    const out = try stripAnsiAlloc(allocator, "before\x1b]0;title\x1b\\after");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("beforeafter", out);
}

test "stripAnsiAlloc handles adversarial unterminated sequences" {
    const allocator = std.testing.allocator;
    // CSI without terminator at end of line should consume rest
    const out = try stripAnsiAlloc(allocator, "a\x1b[31");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a", out);
}

test "stripAnsiAlloc ignores lone ESC bytes" {
    const allocator = std.testing.allocator;
    const out = try stripAnsiAlloc(allocator, "a\x1bb");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a\x1bb", out);
}

test "stripAnsiAlloc handles empty input" {
    const allocator = std.testing.allocator;
    const out = try stripAnsiAlloc(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
