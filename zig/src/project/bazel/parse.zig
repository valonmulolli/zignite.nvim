const std = @import("std");
const common = @import("../core/common.zig");
const model = @import("model.zig");

const Target = model.Target;

const source_keys = [_][]const u8{ "srcs", "hdrs", "textual_hdrs", "main", "src", "sources", "test_srcs", "tests" };
const run_rules = [_][]const u8{ "cc_binary", "go_binary", "java_binary", "py_binary", "rust_binary", "sh_binary" };
const test_rules = [_][]const u8{ "cc_test", "go_test", "java_test", "py_test", "rust_test", "sh_test" };

pub fn parseTargets(allocator: std.mem.Allocator, contents: []const u8) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |item| {
            allocator.free(item.rule_name);
            allocator.free(item.name);
            common.freeOwnedNameList(allocator, item.source_entries);
        }
        targets.deinit(allocator);
    }

    var capture_rule: ?[]const u8 = null;
    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var depth: isize = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        if (capture_rule == null) {
            const rule_name = parseRuleName(line) orelse continue;
            var list: std.ArrayList(u8) = .empty;
            try list.appendSlice(allocator, line);
            depth = countParenDelta(line);
            if (depth <= 0) {
                try commitBlock(allocator, rule_name, list.items, &targets);
                list.deinit(allocator);
            } else {
                capture_rule = rule_name;
                capture = list;
            }
        } else {
            try capture.?.append(allocator, '\n');
            try capture.?.appendSlice(allocator, line);
            depth += countParenDelta(line);
            if (depth <= 0) {
                try commitBlock(allocator, capture_rule.?, capture.?.items, &targets);
                capture.?.deinit(allocator);
                capture = null;
                capture_rule = null;
            }
        }
    }

    return try targets.toOwnedSlice(allocator);
}

fn commitBlock(
    allocator: std.mem.Allocator,
    rule_name: []const u8,
    block: []const u8,
    targets: *std.ArrayList(Target),
) !void {
    if (std.mem.eql(u8, rule_name, "load") or std.mem.eql(u8, rule_name, "package")) return;

    const target_name = parseNamedString(block, "name") orelse return;
    if (target_name.len == 0) return;

    for (targets.items) |item| {
        if (std.mem.eql(u8, item.name, target_name)) return;
    }

    var source_entries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (source_entries.items) |entry| allocator.free(entry);
        source_entries.deinit(allocator);
    }
    try collectRuleSourceEntries(allocator, block, &source_entries);

    try targets.append(allocator, .{
        .rule_name = try allocator.dupe(u8, rule_name),
        .name = try allocator.dupe(u8, target_name),
        .supports_run = ruleSupportsRun(rule_name, block),
        .supports_test = ruleSupportsTest(rule_name, target_name, source_entries.items),
        .source_entries = try source_entries.toOwnedSlice(allocator),
    });
}

fn stripHashComment(line: []const u8) []const u8 {
    const hash_idx = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash_idx];
}

fn parseRuleName(line: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < line.len and isWhitespace(line[index])) : (index += 1) {}
    if (index >= line.len or !isIdentStart(line[index])) return null;

    const start = index;
    index += 1;
    while (index < line.len and isIdentContinue(line[index])) : (index += 1) {}
    const rule_name = line[start..index];
    while (index < line.len and isWhitespace(line[index])) : (index += 1) {}
    if (index >= line.len or line[index] != '(') return null;
    return rule_name;
}

fn countParenDelta(text: []const u8) isize {
    var delta: isize = 0;
    for (text) |ch| {
        if (ch == '(') delta += 1;
        if (ch == ')') delta -= 1;
    }
    return delta;
}

fn collectRuleSourceEntries(
    allocator: std.mem.Allocator,
    block: []const u8,
    source_entries: *std.ArrayList([]u8),
) !void {
    for (source_keys) |key| {
        if (parseNamedString(block, key)) |value| {
            try common.pushUniqueName(allocator, source_entries, value);
        }
        if (parseStringListBody(block, key)) |list_body| {
            try collectQuotedValues(allocator, list_body, source_entries);
        }
        if (parseGlobListBody(block, key)) |glob_body| {
            try collectQuotedValues(allocator, glob_body, source_entries);
        }
    }
}

fn collectQuotedValues(
    allocator: std.mem.Allocator,
    text: []const u8,
    source_entries: *std.ArrayList([]u8),
) !void {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const quote = text[index];
        if (quote != '"' and quote != '\'') continue;
        const start = index + 1;
        index = start;
        while (index < text.len and text[index] != quote) : (index += 1) {}
        if (index > start and index < text.len and text[index] == quote) {
            try common.pushUniqueName(allocator, source_entries, text[start..index]);
        }
    }
}

fn parseNamedString(block: []const u8, key: []const u8) ?[]const u8 {
    const start = findAssignmentValueStart(block, key) orelse return null;
    if (start >= block.len) return null;
    const quote = block[start];
    if (quote != '"' and quote != '\'') return null;

    var index = start + 1;
    while (index < block.len and block[index] != quote) : (index += 1) {}
    if (index <= start + 1 or index >= block.len or block[index] != quote) return null;
    return block[start + 1 .. index];
}

fn parseStringListBody(block: []const u8, key: []const u8) ?[]const u8 {
    const start = findAssignmentValueStart(block, key) orelse return null;
    if (start >= block.len or block[start] != '[') return null;
    return findEnclosedList(block, start, '[', ']');
}

fn parseGlobListBody(block: []const u8, key: []const u8) ?[]const u8 {
    var start = findAssignmentValueStart(block, key) orelse return null;
    if (start + 4 > block.len or !std.mem.eql(u8, block[start .. start + 4], "glob")) return null;
    start += 4;
    while (start < block.len and isWhitespace(block[start])) : (start += 1) {}
    if (start >= block.len or block[start] != '(') return null;
    start += 1;
    while (start < block.len and isWhitespace(block[start])) : (start += 1) {}
    if (start >= block.len or block[start] != '[') return null;
    return findEnclosedList(block, start, '[', ']');
}

fn findEnclosedList(block: []const u8, open_idx: usize, open_ch: u8, close_ch: u8) ?[]const u8 {
    if (open_idx >= block.len or block[open_idx] != open_ch) return null;
    var depth: isize = 0;
    var index = open_idx;
    while (index < block.len) : (index += 1) {
        if (block[index] == open_ch) depth += 1;
        if (block[index] == close_ch) {
            depth -= 1;
            if (depth == 0) {
                return block[open_idx + 1 .. index];
            }
        }
    }
    return null;
}

fn findAssignmentValueStart(block: []const u8, key: []const u8) ?usize {
    var index: usize = 0;
    while (index + key.len <= block.len) : (index += 1) {
        if (!std.mem.eql(u8, block[index .. index + key.len], key)) continue;
        if (index > 0 and isIdentContinue(block[index - 1])) continue;
        if (index + key.len < block.len and isIdentContinue(block[index + key.len])) continue;

        var cursor = index + key.len;
        while (cursor < block.len and isWhitespace(block[cursor])) : (cursor += 1) {}
        if (cursor >= block.len or block[cursor] != '=') continue;
        cursor += 1;
        while (cursor < block.len and isWhitespace(block[cursor])) : (cursor += 1) {}
        return cursor;
    }
    return null;
}

fn ruleSupportsRun(rule_name: []const u8, block: []const u8) bool {
    for (run_rules) |entry| {
        if (std.mem.eql(u8, entry, rule_name)) return true;
    }

    const lower = std.ascii.allocLowerString(std.heap.page_allocator, rule_name) catch return false;
    defer std.heap.page_allocator.free(lower);
    if (std.mem.indexOf(u8, lower, "test") != null) return false;
    if (std.mem.indexOf(u8, lower, "binary") != null or std.mem.indexOf(u8, lower, "_bin") != null) return true;
    return parseNamedString(block, "main") != null or parseNamedString(block, "entry_point") != null;
}

fn ruleSupportsTest(rule_name: []const u8, target_name: []const u8, source_entries: [][]u8) bool {
    for (test_rules) |entry| {
        if (std.mem.eql(u8, entry, rule_name)) return true;
    }

    const lower_rule = std.ascii.allocLowerString(std.heap.page_allocator, rule_name) catch return false;
    defer std.heap.page_allocator.free(lower_rule);
    if (std.mem.indexOf(u8, lower_rule, "test") != null or std.mem.indexOf(u8, lower_rule, "spec") != null) {
        return true;
    }
    if (looksLikeTestName(target_name)) return true;
    for (source_entries) |entry| {
        if (looksLikeTestName(entry)) return true;
    }
    return false;
}

fn looksLikeTestName(value: []const u8) bool {
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, value) catch return false;
    defer std.heap.page_allocator.free(lower);
    return std.mem.indexOf(u8, lower, "test") != null or std.mem.indexOf(u8, lower, "spec") != null;
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "parse bazel targets" {
    const allocator = std.testing.allocator;
    const contents =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
        \\
        \\wrapped_cc_binary(
        \\    name = "tool",
        \\    main = "tool.py",
        \\)
        \\
        \\cc_test(
        \\    name = "main_test",
        \\    srcs = glob(["*_test.cc"]),
        \\)
    ;

    const targets = try parseTargets(allocator, contents);
    defer model.freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 3), targets.len);
    try std.testing.expectEqualStrings("cc_binary", targets[0].rule_name);
    try std.testing.expectEqualStrings("main", targets[0].name);
    try std.testing.expect(targets[0].supports_run);
    try std.testing.expect(!targets[0].supports_test);
    try std.testing.expectEqual(@as(usize, 1), targets[0].source_entries.len);
    try std.testing.expectEqualStrings("main.cc", targets[0].source_entries[0]);

    try std.testing.expectEqualStrings("tool", targets[1].name);
    try std.testing.expect(targets[1].supports_run);

    try std.testing.expectEqualStrings("main_test", targets[2].name);
    try std.testing.expect(targets[2].supports_test);
    try std.testing.expectEqualStrings("*_test.cc", targets[2].source_entries[0]);
}
