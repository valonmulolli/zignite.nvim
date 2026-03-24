const std = @import("std");
const common = @import("core/common.zig");

pub const Target = struct {
    name: []u8,
    matched: bool,
};

pub fn freeOwnedTargets(allocator: std.mem.Allocator, items: []Target) void {
    for (items) |item| {
        allocator.free(item.name);
    }
    allocator.free(items);
}

pub fn parseTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    meson_build_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const root = std.fs.path.dirname(meson_build_path) orelse "";
    const normalized_root = try common.normalizePathAlloc(allocator, root);
    defer allocator.free(normalized_root);

    var relative_match_path: ?[]u8 = null;
    defer if (relative_match_path) |value| allocator.free(value);
    var basename: ?[]u8 = null;
    defer if (basename) |value| allocator.free(value);

    if (match_path) |raw_match_path| {
        const normalized_match = try common.normalizePathAlloc(allocator, raw_match_path);
        defer allocator.free(normalized_match);
        relative_match_path = try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized_match);
        basename = try allocator.dupe(u8, std.fs.path.basename(normalized_match));
    }

    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |item| allocator.free(item.name);
        targets.deinit(allocator);
    }

    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var depth: isize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (capture == null) {
            const start_idx = indexOfExecutable(line) orelse continue;
            var list: std.ArrayList(u8) = .empty;
            try list.appendSlice(allocator, line[start_idx..]);
            depth = countParenDelta(line[start_idx..]);
            if (depth <= 0) {
                try commitBlock(allocator, list.items, relative_match_path, basename, &targets);
                list.deinit(allocator);
            } else {
                capture = list;
            }
        } else {
            try capture.?.append(allocator, ' ');
            try capture.?.appendSlice(allocator, line);
            depth += countParenDelta(line);
            if (depth <= 0) {
                try commitBlock(allocator, capture.?.items, relative_match_path, basename, &targets);
                capture.?.deinit(allocator);
                capture = null;
            }
        }
    }

    return try targets.toOwnedSlice(allocator);
}

fn commitBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    targets: *std.ArrayList(Target),
) !void {
    const args = extractExecutableArgs(block) orelse return;
    const tokens = try tokenizeQuotedArgsAlloc(allocator, args);
    defer common.freeOwnedNameList(allocator, tokens);
    if (tokens.len == 0) return;

    const target = tokens[0];
    if (target.len == 0) return;

    var matched = false;
    if (relative_match_path != null or basename != null) {
        var index: usize = 1;
        while (index < tokens.len) : (index += 1) {
            const normalized_source = try common.normalizePathAlloc(allocator, tokens[index]);
            defer allocator.free(normalized_source);
            if (normalized_source.len == 0) continue;
            if (relative_match_path) |relative_path| {
                if (std.mem.eql(u8, normalized_source, relative_path)) {
                    matched = true;
                    break;
                }
            }
            if (basename) |file_basename| {
                if (std.mem.eql(u8, normalized_source, file_basename)) {
                    matched = true;
                    break;
                }
                if (std.mem.endsWith(u8, normalized_source, file_basename)) {
                    const prefix_len = normalized_source.len - file_basename.len;
                    if (prefix_len > 0 and normalized_source[prefix_len - 1] == '/') {
                        matched = true;
                        break;
                    }
                }
            }
        }
    }

    for (targets.items) |*item| {
        if (std.mem.eql(u8, item.name, target)) {
            item.matched = item.matched or matched;
            return;
        }
    }

    try targets.append(allocator, .{
        .name = try allocator.dupe(u8, target),
        .matched = matched,
    });
}

fn stripHashComment(line: []const u8) []const u8 {
    const hash_idx = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash_idx];
}

fn indexOfExecutable(line: []const u8) ?usize {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (std.ascii.toLower(line[index]) != 'e') continue;
        const remaining = line[index..];
        if (remaining.len < "executable".len) continue;
        if (std.ascii.eqlIgnoreCase(remaining[0.."executable".len], "executable")) {
            return index;
        }
    }
    return null;
}

fn extractExecutableArgs(block: []const u8) ?[]const u8 {
    const open_idx = std.mem.indexOfScalar(u8, block, '(') orelse return null;
    const close_idx = std.mem.lastIndexOfScalar(u8, block, ')') orelse return null;
    if (close_idx <= open_idx) return null;
    return block[open_idx + 1 .. close_idx];
}

fn countParenDelta(text: []const u8) isize {
    var delta: isize = 0;
    for (text) |ch| {
        if (ch == '(') delta += 1;
        if (ch == ')') delta -= 1;
    }
    return delta;
}

fn tokenizeQuotedArgsAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer common.freeOwnedNameList(allocator, tokens.items);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const quote = text[index];
        if (quote != '"' and quote != '\'') continue;
        const start = index + 1;
        index = start;
        while (index < text.len and text[index] != quote) : (index += 1) {}
        if (index > start and index < text.len and text[index] == quote) {
            try common.pushUniqueName(allocator, &tokens, text[start..index]);
        }
    }

    return try tokens.toOwnedSlice(allocator);
}

test "parse meson executable targets" {
    const allocator = std.testing.allocator;
    const contents =
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp', 'src/lib.cpp')
        \\executable(
        \\  'tool',
        \\  'tools/tool.cpp',
        \\)
    ;

    const targets = try parseTargets(allocator, contents, "/tmp/mesonproj/meson.build", "/tmp/mesonproj/src/main.cpp");
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("demo-app", targets[0].name);
    try std.testing.expect(targets[0].matched);
    try std.testing.expectEqualStrings("tool", targets[1].name);
    try std.testing.expect(!targets[1].matched);
}
