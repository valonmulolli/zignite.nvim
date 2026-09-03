const std = @import("std");
const common = @import("../core/common.zig");
const pathing = @import("../../pathing.zig");

pub const Target = struct {
    name: []u8,
    matched: bool,
    exact_match: bool = false,
    artifact_path: ?[]u8 = null,
};

const MatchKind = enum {
    none,
    basename,
    exact,
};

pub fn freeOwnedTargets(allocator: std.mem.Allocator, items: []Target) void {
    for (items) |item| {
        allocator.free(item.name);
        if (item.artifact_path) |artifact_path| allocator.free(artifact_path);
    }
    allocator.free(items);
}

pub fn parseTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    meson_build_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const root = pathing.dirOrDot(meson_build_path);
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

    try parseExecutableBlocks(allocator, contents, relative_match_path, basename, &targets);

    return try targets.toOwnedSlice(allocator);
}

fn parseExecutableBlocks(
    allocator: std.mem.Allocator,
    contents: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    targets: *std.ArrayList(Target),
) !void {
    const source = try stripHashCommentsAlloc(allocator, contents);
    defer allocator.free(source);

    var cursor: usize = 0;
    while (cursor < source.len) {
        const command_index = indexOfExecutable(source[cursor..]) orelse break;
        const block_start = cursor + command_index;
        const open_offset = std.mem.findScalar(u8, source[block_start..], '(') orelse break;
        const open_index = block_start + open_offset;
        const close_index = findMatchingParen(source[open_index..]) orelse break;
        const block_end = open_index + close_index + 1;

        try commitBlock(allocator, source[block_start..block_end], relative_match_path, basename, targets);
        cursor = block_end;
    }
}

fn stripHashCommentsAlloc(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        try source.appendSlice(allocator, stripHashComment(common.stripTrailingCR(raw_line)));
        try source.append(allocator, '\n');
    }

    return try source.toOwnedSlice(allocator);
}

fn findMatchingParen(text: []const u8) ?usize {
    const open_index = std.mem.findScalar(u8, text, '(') orelse return null;
    var depth: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    for (text[open_index..], 0..) |ch, offset| {
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == active_quote) quote = null;
            continue;
        }

        if (ch == '\'' or ch == '"') {
            quote = ch;
            continue;
        }
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return open_index + offset;
        }
    }

    return null;
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
    if (target.len == 0 or common.hasInvalidPayloadChars(target)) return;

    var match_kind: MatchKind = .none;
    if (relative_match_path != null or basename != null) {
        var index: usize = 1;
        while (index < tokens.len) : (index += 1) {
            const normalized_source = try common.normalizePathAlloc(allocator, tokens[index]);
            defer allocator.free(normalized_source);
            if (normalized_source.len == 0) continue;
            if (relative_match_path) |relative_path| {
                if (std.mem.eql(u8, normalized_source, relative_path)) {
                    match_kind = .exact;
                    break;
                }
            }
            if (basename) |file_basename| {
                if (std.mem.eql(u8, normalized_source, file_basename)) {
                    match_kind = .basename;
                    continue;
                }
                if (std.mem.endsWith(u8, normalized_source, file_basename)) {
                    const prefix_len = normalized_source.len - file_basename.len;
                    if (prefix_len > 0 and normalized_source[prefix_len - 1] == '/') {
                        match_kind = .basename;
                    }
                }
            }
        }
    }

    for (targets.items) |*item| {
        if (std.mem.eql(u8, item.name, target)) {
            item.matched = item.matched or match_kind != .none;
            item.exact_match = item.exact_match or match_kind == .exact;
            return;
        }
    }

    const owned_name = try allocator.dupe(u8, target);
    targets.append(allocator, .{
        .name = owned_name,
        .matched = match_kind != .none,
        .exact_match = match_kind == .exact,
        .artifact_path = null,
    }) catch |err| {
        allocator.free(owned_name);
        return err;
    };
}

fn stripHashComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;

    for (line, 0..) |ch, index| {
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == active_quote) {
                quote = null;
            }
            continue;
        }

        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') return line[0..index];
    }

    return line;
}

fn indexOfExecutable(line: []const u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (quote) |active_quote| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (line[index] == '\\') {
                escaped = true;
                continue;
            }
            if (line[index] == active_quote) quote = null;
            continue;
        }

        if (line[index] == '"' or line[index] == '\'') {
            quote = line[index];
            continue;
        }
        if (std.ascii.toLower(line[index]) != 'e') continue;
        const remaining = line[index..];
        if (remaining.len < "executable".len) continue;
        if (!std.ascii.eqlIgnoreCase(remaining[0.."executable".len], "executable")) continue;
        if (index > 0 and isIdentifierChar(line[index - 1])) continue;
        const after = index + "executable".len;
        if (after >= line.len or line[after] == '(' or std.ascii.isWhitespace(line[after])) return index;
    }
    return null;
}

fn extractExecutableArgs(block: []const u8) ?[]const u8 {
    const open_idx = std.mem.findScalar(u8, block, '(') orelse return null;
    const close_idx = findMatchingParen(block) orelse return null;
    if (close_idx <= open_idx) return null;
    return block[open_idx + 1 .. close_idx];
}

fn countParenDelta(text: []const u8) isize {
    var delta: isize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (text) |ch| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote) |active_quote| {
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == active_quote) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '(') delta += 1;
        if (ch == ')') delta -= 1;
    }
    return delta;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn tokenizeQuotedArgsAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer common.deinitOwnedNameList(allocator, &tokens);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const quote = text[index];
        if (quote != '"' and quote != '\'') continue;
        const start = index + 1;
        index = start;
        while (index < text.len and text[index] != quote) : (index += 1) {}
        if (index < text.len and text[index] == quote) {
            const token = try allocator.dupe(u8, text[start..index]);
            tokens.append(allocator, token) catch |err| {
                allocator.free(token);
                return err;
            };
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

test "parse meson ignores executable text inside strings and identifiers" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "message('executable(fake, src.cpp)')\nmy_executable('wrong', 'src.cpp')\nexecutable('real', 'src/main.cpp')\n",
        "/tmp/mesonproj/meson.build",
        "/tmp/mesonproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("real", targets[0].name);
    try std.testing.expect(targets[0].matched);
}

test "parse meson ignores parentheses inside quoted sources" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "executable(\n  'app',\n  'src/part(.cpp',\n)\nexecutable('other', 'src/other.cpp')\n",
        "/tmp/mesonproj/meson.build",
        "/tmp/mesonproj/src/part(.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
    try std.testing.expectEqualStrings("other", targets[1].name);
}

test "parse meson targets finds multiple commands on one line" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "executable('first', 'src/first.cpp') executable('second', 'src/second.cpp')\n",
        "/tmp/mesonproj/meson.build",
        "/tmp/mesonproj/src/second.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expect(!targets[0].matched);
    try std.testing.expect(targets[1].matched);
}

test "parse meson prefers exact source matches over basename matches" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "executable('first', 'src/a/main.cpp') executable('second', 'src/b/main.cpp')\n",
        "/tmp/mesonproj/meson.build",
        "/tmp/mesonproj/src/b/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expect(targets[0].matched);
    try std.testing.expect(!targets[0].exact_match);
    try std.testing.expect(targets[1].matched);
    try std.testing.expect(targets[1].exact_match);
}

test "parse meson rejects unsafe target without shifting source arguments" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "executable('bad@@ZQF_BEGIN', 'src/main.cpp')\n",
        "/tmp/mesonproj/meson.build",
        "/tmp/mesonproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 0), targets.len);

    const empty_targets = try parseTargets(
        allocator,
        "executable('', 'src/main.cpp')\n",
        "/tmp/mesonproj/meson.build",
        "/tmp/mesonproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, empty_targets);

    try std.testing.expectEqual(@as(usize, 0), empty_targets.len);
}
