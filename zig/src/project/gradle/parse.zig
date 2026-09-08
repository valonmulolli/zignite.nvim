const std = @import("std");
const common = @import("../core/common.zig");

pub fn parseTasks(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    const source = try stripCommentsAlloc(allocator, contents);
    defer allocator.free(source);

    try common.pushUniqueName(allocator, names, "build");
    try common.pushUniqueName(allocator, names, "test");
    try common.pushUniqueName(allocator, names, "clean");

    if (containsSpringBoot(source)) {
        try common.pushUniqueName(allocator, names, "bootRun");
    }
    if (containsApplicationRun(source)) {
        try common.pushUniqueName(allocator, names, "run");
    }

    try collectDeclaredTasks(allocator, source, names);
}

fn stripCommentsAlloc(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    const source = try allocator.alloc(u8, contents.len);
    errdefer allocator.free(source);

    var input_index: usize = 0;
    var output_index: usize = 0;
    var quote: u8 = 0;
    var triple_quote = false;
    var block_comment = false;

    while (input_index < contents.len) {
        const current = contents[input_index];

        if (block_comment) {
            if (current == '*' and input_index + 1 < contents.len and contents[input_index + 1] == '/') {
                source[output_index] = ' ';
                source[output_index + 1] = ' ';
                output_index += 2;
                input_index += 2;
                block_comment = false;
            } else {
                source[output_index] = if (current == '\n') '\n' else ' ';
                output_index += 1;
                input_index += 1;
            }
            continue;
        }

        if (quote != 0) {
            if (triple_quote and input_index + 2 < contents.len and
                contents[input_index] == quote and
                contents[input_index + 1] == quote and
                contents[input_index + 2] == quote)
            {
                @memset(source[output_index .. output_index + 3], ' ');
                output_index += 3;
                input_index += 3;
                quote = 0;
                triple_quote = false;
                continue;
            }

            if (triple_quote) {
                source[output_index] = if (current == '\n') '\n' else ' ';
                output_index += 1;
                input_index += 1;
                continue;
            }

            source[output_index] = current;
            output_index += 1;
            input_index += 1;
            if (!triple_quote and current == '\\' and input_index < contents.len) {
                source[output_index] = contents[input_index];
                output_index += 1;
                input_index += 1;
            } else if (!triple_quote and current == quote) {
                quote = 0;
            }
            continue;
        }

        if (current == '/' and input_index + 1 < contents.len) {
            const next = contents[input_index + 1];
            if (next == '/') {
                source[output_index] = ' ';
                source[output_index + 1] = ' ';
                output_index += 2;
                input_index += 2;
                while (input_index < contents.len and contents[input_index] != '\n') {
                    source[output_index] = ' ';
                    output_index += 1;
                    input_index += 1;
                }
                continue;
            }
            if (next == '*') {
                source[output_index] = ' ';
                source[output_index + 1] = ' ';
                output_index += 2;
                input_index += 2;
                block_comment = true;
                continue;
            }
        }

        if (current == '\'' or current == '"') {
            quote = current;
            triple_quote = input_index + 2 < contents.len and
                contents[input_index + 1] == current and
                contents[input_index + 2] == current;
            if (triple_quote) {
                @memset(source[output_index .. output_index + 3], ' ');
                output_index += 3;
                input_index += 3;
            } else {
                source[output_index] = current;
                output_index += 1;
                input_index += 1;
            }
            continue;
        }

        source[output_index] = current;
        output_index += 1;
        input_index += 1;
    }

    return source;
}

fn containsSpringBoot(contents: []const u8) bool {
    return std.mem.find(u8, contents, "org.springframework.boot") != null;
}

fn containsApplicationRun(contents: []const u8) bool {
    const patterns = [_][]const u8{
        "id 'application'",
        "id \"application\"",
        "id(\"application\")",
        "apply plugin: 'application'",
        "apply plugin: \"application\"",
        "application {",
        "application{",
    };
    for (patterns) |pattern| {
        if (findCodePrefix(contents, pattern, 0) != null) return true;
    }
    return false;
}

fn collectDeclaredTasks(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimSpaces(common.stripTrailingCR(raw_line));
        if (line.len == 0) continue;

        var quoted_task_index: usize = 0;
        var found_quoted_task = false;
        while (extractNextQuotedTaskName(line, quoted_task_index)) |match| {
            try common.pushUniqueName(allocator, names, match.name);
            found_quoted_task = true;
            quoted_task_index = match.next_index;
        }
        if (found_quoted_task) {
            continue;
        }

        if (extractRegisteredValueTaskName(line)) |name| {
            try common.pushUniqueName(allocator, names, name);
            continue;
        }

        if (extractBareTaskName(line)) |name| {
            try common.pushUniqueName(allocator, names, name);
        }
    }
}

const QuotedTaskMatch = struct {
    name: []const u8,
    next_index: usize,
};

fn extractNextQuotedTaskName(line: []const u8, start_index: usize) ?QuotedTaskMatch {
    const prefixes = [_][]const u8{
        "tasks.register",
        "tasks.create",
        "tasks.named",
        "task(",
    };

    var prefix_index: ?usize = null;
    var prefix_len: usize = 0;
    for (prefixes) |prefix| {
        const index = findCodePrefix(line, prefix, start_index) orelse continue;
        if (prefix_index == null or index < prefix_index.?) {
            prefix_index = index;
            prefix_len = prefix.len;
        }
    }
    const index = prefix_index orelse return null;
    const rest = line[index + prefix_len ..];
    const quote_index = std.mem.findAny(u8, rest, "\"'") orelse return null;
    const quote = rest[quote_index];
    const name_start = quote_index + 1;
    const name_end = std.mem.findScalarPos(u8, rest, name_start, quote) orelse return null;
    const name = rest[name_start..name_end];
    if (name.len == 0) return null;
    return .{
        .name = name,
        .next_index = index + prefix_len + name_end + 1,
    };
}

fn findCodePrefix(line: []const u8, prefix: []const u8, start_index: usize) ?usize {
    var index: usize = start_index;
    var quote: u8 = 0;
    var triple_quote = false;

    while (index < line.len) {
        const current = line[index];

        if (quote != 0) {
            if (triple_quote and index + 2 < line.len and
                line[index] == quote and
                line[index + 1] == quote and
                line[index + 2] == quote)
            {
                index += 3;
                quote = 0;
                triple_quote = false;
                continue;
            }

            if (!triple_quote and current == '\\' and index + 1 < line.len) {
                index += 2;
                continue;
            }
            if (!triple_quote and current == quote) quote = 0;
            index += 1;
            continue;
        }

        if (current == '\'' or current == '"') {
            quote = current;
            triple_quote = index + 2 < line.len and
                line[index + 1] == current and
                line[index + 2] == current;
            index += if (triple_quote) 3 else 1;
            continue;
        }

        if (std.mem.startsWith(u8, line[index..], prefix) and
            (index == 0 or !isIdentifierChar(line[index - 1])) and
            (index + prefix.len == line.len or !isIdentifierChar(line[index + prefix.len])))
        {
            return index;
        }
        index += 1;
    }

    return null;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

fn extractRegisteredValueTaskName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "val ")) return null;
    if (std.mem.find(u8, line, " by tasks.") == null and std.mem.find(u8, line, " by tasks") == null) return null;
    if (std.mem.find(u8, line, "register") == null and std.mem.find(u8, line, "create") == null and std.mem.find(u8, line, "named") == null) return null;

    const rest = line["val ".len..];
    const end = scanTaskNameEnd(rest);
    if (end == 0) return null;
    return rest[0..end];
}

fn extractBareTaskName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "task ")) return null;
    const rest = common.trimSpaces(line["task ".len..]);
    if (rest.len == 0) return null;
    if (rest[0] == '"' or rest[0] == '\'') return null;

    const end = scanTaskNameEnd(rest);
    if (end == 0) return null;
    return rest[0..end];
}

fn scanTaskNameEnd(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and isTaskNameChar(text[index])) : (index += 1) {}
    return index;
}

fn isTaskNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ':' or ch == '.';
}

fn containsName(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

test "parse gradle tasks" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator,
        \\plugins {
        \\    id("application")
        \\    id("org.springframework.boot") version "3.5.0"
        \\}
    , &names);

    try std.testing.expectEqual(@as(usize, 5), names.items.len);
    try std.testing.expectEqualStrings("build", names.items[0]);
    try std.testing.expectEqualStrings("test", names.items[1]);
    try std.testing.expectEqualStrings("clean", names.items[2]);
    try std.testing.expectEqualStrings("bootRun", names.items[3]);
    try std.testing.expectEqualStrings("run", names.items[4]);
}

test "parse gradle tasks discovers declared tasks across common styles" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator,
        \\tasks.register("integrationTest")
        \\tasks.register<Test>("spotlessApply")
        \\tasks.create("bundle")
        \\tasks.named("preview")
        \\val smokeTest by tasks.registering
        \\task e2e(type: Test)
        \\task("dist")
    , &names);

    try std.testing.expect(containsName(names.items, "build"));
    try std.testing.expect(containsName(names.items, "test"));
    try std.testing.expect(containsName(names.items, "clean"));
    try std.testing.expect(containsName(names.items, "integrationTest"));
    try std.testing.expect(containsName(names.items, "spotlessApply"));
    try std.testing.expect(containsName(names.items, "bundle"));
    try std.testing.expect(containsName(names.items, "preview"));
    try std.testing.expect(containsName(names.items, "smokeTest"));
    try std.testing.expect(containsName(names.items, "e2e"));
    try std.testing.expect(containsName(names.items, "dist"));
}

test "parse gradle tasks discovers multiple quoted declarations on one line" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator, "tasks.register(\"first\"); tasks.register(\"second\")\n" ++
        "tasks.create(\"third\"); tasks.named(\"fourth\")\n" ++
        "task(\"fifth\")", &names);

    try std.testing.expect(containsName(names.items, "first"));
    try std.testing.expect(containsName(names.items, "second"));
    try std.testing.expect(containsName(names.items, "third"));
    try std.testing.expect(containsName(names.items, "fourth"));
    try std.testing.expect(containsName(names.items, "fifth"));
}

test "parse gradle tasks ignores commented declarations" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator,
        \\// tasks.register("commentedLine")
        \\/*
        \\tasks.register("commentedBlock")
        \\id("application")
        \\*/
        \\tasks.register("realTask")
    , &names);

    try std.testing.expect(containsName(names.items, "realTask"));
    try std.testing.expect(!containsName(names.items, "commentedLine"));
    try std.testing.expect(!containsName(names.items, "commentedBlock"));
    try std.testing.expect(!containsName(names.items, "run"));
}

test "parse gradle tasks preserves comment markers inside strings" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator,
        \\val url = "https://example.test//notAComment"
        \\val raw = """this // remains text"""
        \\tasks.register("realTask")
    , &names);

    try std.testing.expect(containsName(names.items, "realTask"));
    try std.testing.expect(!containsName(names.items, "run"));
}

test "parse gradle tasks ignores task declarations inside strings" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator,
        \\val text = "tasks.register(\\\"fakeTask\\\")"
        \\val raw = """tasks.create("fakeRawTask")"""
        \\tasks.register("realTask")
    , &names);

    try std.testing.expect(containsName(names.items, "realTask"));
    try std.testing.expect(!containsName(names.items, "fakeTask"));
    try std.testing.expect(!containsName(names.items, "fakeRawTask"));
}

test "parse gradle tasks ignores declarations inside multiline strings" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator,
        \\val raw = """
        \\tasks.register("fakeTask")
        \\id("application")
        \\"""
        \\tasks.register("realTask")
    , &names);

    try std.testing.expect(containsName(names.items, "realTask"));
    try std.testing.expect(!containsName(names.items, "fakeTask"));
    try std.testing.expect(!containsName(names.items, "run"));
}

test "parse gradle tasks ignores application blocks inside strings" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTasks(allocator, "val text = \"application {\"\n" ++
        "val other = \"id('application')\"\n", &names);

    try std.testing.expect(!containsName(names.items, "run"));
}
