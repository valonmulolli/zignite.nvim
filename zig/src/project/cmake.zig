const std = @import("std");
const common = @import("common.zig");

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
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const root = std.fs.path.dirname(cmake_lists_path) orelse "";
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

    const project_name = parseProjectName(contents);
    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var depth: isize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (capture == null) {
            const start_idx = indexOfAddExecutable(line) orelse continue;
            var list: std.ArrayList(u8) = .empty;
            try list.appendSlice(allocator, line[start_idx..]);
            depth = countParenDelta(line[start_idx..]);
            if (depth <= 0) {
                try commitBlock(allocator, list.items, project_name, relative_match_path, basename, &targets);
                list.deinit(allocator);
            } else {
                capture = list;
            }
        } else {
            try capture.?.append(allocator, ' ');
            try capture.?.appendSlice(allocator, line);
            depth += countParenDelta(line);
            if (depth <= 0) {
                try commitBlock(allocator, capture.?.items, project_name, relative_match_path, basename, &targets);
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
    project_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
    targets: *std.ArrayList(Target),
) !void {
    const args = extractAddExecutableArgs(block) orelse return;
    const tokens = try tokenizeWhitespaceArgsAlloc(allocator, args);
    defer common.freeOwnedNameList(allocator, tokens);
    if (tokens.len == 0) return;

    var index: usize = 0;
    while (index < tokens.len) : (index += 1) {
        const token = resolveToken(tokens[index], project_name);
        if (
            std.mem.eql(u8, token, "WIN32")
            or std.mem.eql(u8, token, "MACOSX_BUNDLE")
            or std.mem.eql(u8, token, "EXCLUDE_FROM_ALL")
        ) {
            continue;
        }
        break;
    }
    if (index >= tokens.len) return;

    const target = resolveToken(tokens[index], project_name);
    if (target.len == 0 or std.mem.indexOf(u8, target, "${") != null) return;

    var matched = false;
    if (relative_match_path != null or basename != null) {
        var source_index = index + 1;
        while (source_index < tokens.len) : (source_index += 1) {
            const source_token = resolveToken(tokens[source_index], project_name);
            const normalized_source = try common.normalizePathAlloc(allocator, source_token);
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

fn indexOfAddExecutable(line: []const u8) ?usize {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (std.ascii.toLower(line[index]) != 'a') continue;
        const remaining = line[index..];
        if (remaining.len < "add_executable".len) continue;
        if (std.ascii.eqlIgnoreCase(remaining[0.."add_executable".len], "add_executable")) {
            return index;
        }
    }
    return null;
}

fn extractAddExecutableArgs(block: []const u8) ?[]const u8 {
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

fn stripHashComment(line: []const u8) []const u8 {
    const hash_idx = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash_idx];
}

fn parseProjectName(contents: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        const project_idx = indexOfProjectCall(line) orelse continue;
        const open_idx = std.mem.indexOfScalar(u8, line[project_idx..], '(') orelse continue;
        const args = line[project_idx + open_idx + 1 ..];
        const trimmed = common.trimSpaces(args);
        const token = extractFirstToken(trimmed);
        if (token.len > 0) return token;
    }
    return null;
}

fn indexOfProjectCall(line: []const u8) ?usize {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (std.ascii.toLower(line[index]) != 'p') continue;
        const remaining = line[index..];
        if (remaining.len < "project".len) continue;
        if (std.ascii.eqlIgnoreCase(remaining[0.."project".len], "project")) {
            return index;
        }
    }
    return null;
}

fn extractFirstToken(text: []const u8) []const u8 {
    const trimmed = common.trimSpaces(text);
    if (trimmed.len == 0) return "";
    var start: usize = 0;
    var end: usize = trimmed.len;
    if ((trimmed[0] == '"' or trimmed[0] == '\'') and trimmed.len >= 2) {
        start = 1;
        var close_index = start;
        while (close_index < trimmed.len and trimmed[close_index] != trimmed[0]) : (close_index += 1) {}
        end = close_index;
    } else {
        var idx: usize = 0;
        while (idx < trimmed.len and !std.ascii.isWhitespace(trimmed[idx]) and trimmed[idx] != ')') : (idx += 1) {}
        end = idx;
    }
    return trimmed[start..end];
}

fn resolveToken(token: []const u8, project_name: ?[]const u8) []const u8 {
    if (project_name != null and std.mem.eql(u8, token, "${PROJECT_NAME}")) {
        return project_name.?;
    }
    return token;
}

fn tokenizeWhitespaceArgsAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer common.freeOwnedNameList(allocator, tokens.items);

    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
        if (index >= text.len) break;

        var quote: ?u8 = null;
        var current: std.ArrayList(u8) = .empty;
        errdefer current.deinit(allocator);

        while (index < text.len) : (index += 1) {
            const ch = text[index];
            if (quote) |active_quote| {
                if (ch == active_quote) {
                    quote = null;
                } else {
                    try current.append(allocator, ch);
                }
            } else if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (std.ascii.isWhitespace(ch)) {
                break;
            } else {
                try current.append(allocator, ch);
            }
        }

        const token = common.trimSpaces(current.items);
        if (token.len > 0) {
            try tokens.append(allocator, try allocator.dupe(u8, token));
        }
        current.deinit(allocator);
    }

    return try tokens.toOwnedSlice(allocator);
}

test "parse cmake targets with primary match" {
    const allocator = std.testing.allocator;
    const targets = try parseTargets(
        allocator,
        "project(app)\nadd_executable(\n  app\n  src/main.cpp\n  src/other.cpp\n)\n",
        "/tmp/cmakeproj/CMakeLists.txt",
        "/tmp/cmakeproj/src/main.cpp",
    );
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("app", targets[0].name);
    try std.testing.expect(targets[0].matched);
}
