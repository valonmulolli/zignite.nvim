const std = @import("std");
const common = @import("core/common.zig");

pub const Target = struct {
    rule_name: []u8,
    name: []u8,
    supports_run: bool,
    supports_test: bool,
    source_entries: [][]u8,
};

pub const CommandEntry = struct {
    name: []u8,
    command: []u8,
};

pub const CommandInfo = struct {
    commands: []CommandEntry,
    primary_build: ?[]u8 = null,
    primary_run: ?[]u8 = null,
    primary_test: ?[]u8 = null,
};

const source_keys = [_][]const u8{ "srcs", "hdrs", "textual_hdrs", "main", "src", "sources", "test_srcs", "tests" };
const run_rules = [_][]const u8{ "cc_binary", "go_binary", "java_binary", "py_binary", "rust_binary", "sh_binary" };
const test_rules = [_][]const u8{ "cc_test", "go_test", "java_test", "py_test", "rust_test", "sh_test" };

pub fn freeOwnedTargets(allocator: std.mem.Allocator, items: []Target) void {
    for (items) |item| {
        allocator.free(item.rule_name);
        allocator.free(item.name);
        common.freeOwnedNameList(allocator, item.source_entries);
    }
    allocator.free(items);
}

pub fn freeOwnedCommandInfo(allocator: std.mem.Allocator, info: CommandInfo) void {
    for (info.commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    allocator.free(info.commands);
    if (info.primary_build) |value| allocator.free(value);
    if (info.primary_run) |value| allocator.free(value);
    if (info.primary_test) |value| allocator.free(value);
}

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

pub fn buildCommandInfo(
    allocator: std.mem.Allocator,
    items: []Target,
    build_path: []const u8,
    package_path: []const u8,
    match_path: ?[]const u8,
) !CommandInfo {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        commands.deinit(allocator);
    }

    const package_dir = std.fs.path.dirname(build_path) orelse "";
    var relative_filepath: ?[]u8 = null;
    defer if (relative_filepath) |value| allocator.free(value);
    var basename: ?[]const u8 = null;
    if (match_path) |path| {
        const relative = try common.makeRelativeToRootAlloc(allocator, package_dir, path);
        defer allocator.free(relative);
        relative_filepath = try common.normalizePathAlloc(allocator, relative);
        basename = std.fs.path.basename(path);
    }

    var primary_build: ?[]u8 = null;
    var primary_run: ?[]u8 = null;
    var primary_test: ?[]u8 = null;
    errdefer {
        if (primary_build) |value| allocator.free(value);
        if (primary_run) |value| allocator.free(value);
        if (primary_test) |value| allocator.free(value);
    }

    for (items) |item| {
        const label = try bazelLabelAlloc(allocator, package_path, item.name);
        defer allocator.free(label);

        try appendCommandEntry(
            allocator,
            &commands,
            try std.fmt.allocPrint(allocator, "bazel-build-{s}", .{item.name}),
            try std.fmt.allocPrint(allocator, "bazel build {s}", .{label}),
        );

        if (item.supports_run) {
            try appendCommandEntry(
                allocator,
                &commands,
                try std.fmt.allocPrint(allocator, "bazel-run-{s}", .{item.name}),
                try std.fmt.allocPrint(allocator, "bazel run {s}", .{label}),
            );
        }

        if (item.supports_test) {
            try appendCommandEntry(
                allocator,
                &commands,
                try std.fmt.allocPrint(allocator, "bazel-test-{s}", .{item.name}),
                try std.fmt.allocPrint(allocator, "bazel test {s}", .{label}),
            );
        }

        const matched = if (relative_filepath != null and basename != null)
            targetMatchesFile(item, relative_filepath.?, basename.?)
        else
            false;

        if (matched and primary_build == null) {
            primary_build = try std.fmt.allocPrint(allocator, "bazel build {s}", .{label});
        }
        if (matched and item.supports_run and primary_run == null) {
            primary_run = try std.fmt.allocPrint(allocator, "bazel run {s}", .{label});
        }
        if (matched and item.supports_test and primary_test == null) {
            primary_test = try std.fmt.allocPrint(allocator, "bazel test {s}", .{label});
        }

        if (primary_test == null and item.supports_test and match_path != null) {
            if (sourceEntriesAreRelatedToFile(allocator, item.source_entries, match_path.?)) {
                primary_test = try std.fmt.allocPrint(allocator, "bazel test {s}", .{label});
            }
        }
    }

    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .primary_build = primary_build,
        .primary_run = primary_run,
        .primary_test = primary_test,
    };
}

pub fn buildWorkspaceCommandInfo(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    match_path: ?[]const u8,
) !CommandInfo {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        commands.deinit(allocator);
    }

    if (match_path == null or match_path.?.len == 0) {
        return .{ .commands = try commands.toOwnedSlice(allocator) };
    }

    const normalized_root = try common.normalizePathAlloc(allocator, workspace_root);
    defer allocator.free(normalized_root);

    const normalized_match = try common.normalizePathAlloc(allocator, match_path.?);
    defer allocator.free(normalized_match);

    var current_dir = try allocator.dupe(u8, std.fs.path.dirname(normalized_match) orelse normalized_match);
    defer allocator.free(current_dir);

    var primary_build: ?[]u8 = null;
    var primary_run: ?[]u8 = null;
    var primary_test: ?[]u8 = null;
    errdefer {
        if (primary_build) |value| allocator.free(value);
        if (primary_run) |value| allocator.free(value);
        if (primary_test) |value| allocator.free(value);
    }

    while (current_dir.len > 0) {
        const build_file = try findBuildFileAlloc(allocator, current_dir);
        if (build_file) |path| {
            defer allocator.free(path);

            const contents = common.readFileAlloc(allocator, path) catch continue;
            defer allocator.free(contents);

            const items = try parseTargets(allocator, contents);
            defer freeOwnedTargets(allocator, items);

            const package_path = try packagePathFromDirAlloc(allocator, current_dir, normalized_root);
            defer allocator.free(package_path);

            const info = try buildCommandInfo(allocator, items, path, package_path, normalized_match);
            defer freeOwnedCommandInfo(allocator, info);

            for (info.commands) |entry| {
                try commands.append(allocator, .{
                    .name = try allocator.dupe(u8, entry.name),
                    .command = try allocator.dupe(u8, entry.command),
                });
            }

            if (info.primary_build) |value| {
                if (primary_build) |existing| allocator.free(existing);
                primary_build = try allocator.dupe(u8, value);
            }
            if (info.primary_run) |value| {
                if (primary_run) |existing| allocator.free(existing);
                primary_run = try allocator.dupe(u8, value);
            }
            if (info.primary_test) |value| {
                if (primary_test) |existing| allocator.free(existing);
                primary_test = try allocator.dupe(u8, value);
            }
        }

        if (std.mem.eql(u8, current_dir, normalized_root)) break;
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;

        allocator.free(current_dir);
        current_dir = try allocator.dupe(u8, parent);
    }

    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .primary_build = primary_build,
        .primary_run = primary_run,
        .primary_test = primary_test,
    };
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn findBuildFileAlloc(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const build_bazel = try std.fs.path.join(allocator, &.{ dir, "BUILD.bazel" });
    errdefer allocator.free(build_bazel);
    if (pathExists(build_bazel)) return build_bazel;
    allocator.free(build_bazel);

    const build = try std.fs.path.join(allocator, &.{ dir, "BUILD" });
    if (pathExists(build)) return build;
    allocator.free(build);
    return null;
}

fn packagePathFromDirAlloc(allocator: std.mem.Allocator, dir: []const u8, workspace_root: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, workspace_root)) {
        return allocator.dupe(u8, "");
    }
    if (workspace_root.len > 0 and
        dir.len > workspace_root.len and
        std.mem.startsWith(u8, dir, workspace_root) and
        dir[workspace_root.len] == '/')
    {
        return allocator.dupe(u8, dir[workspace_root.len + 1 ..]);
    }
    return allocator.dupe(u8, "");
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

fn appendCommandEntry(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(CommandEntry),
    owned_name: []u8,
    owned_command: []u8,
) !void {
    errdefer allocator.free(owned_name);
    errdefer allocator.free(owned_command);
    try commands.append(allocator, .{
        .name = owned_name,
        .command = owned_command,
    });
}

fn bazelLabelAlloc(allocator: std.mem.Allocator, package_path: []const u8, target_name: []const u8) ![]u8 {
    if (package_path.len == 0) {
        return std.fmt.allocPrint(allocator, "//:{s}", .{target_name});
    }
    return std.fmt.allocPrint(allocator, "//{s}:{s}", .{ package_path, target_name });
}

fn targetMatchesFile(item: Target, relative_filepath: []const u8, basename: []const u8) bool {
    for (item.source_entries) |source_entry| {
        if (sourceMatchesFile(source_entry, relative_filepath, basename)) {
            return true;
        }
    }
    return globMatchesFile(item.source_entries, relative_filepath, basename);
}

fn sourceMatchesFile(source_entry: []const u8, relative_filepath: []const u8, basename: []const u8) bool {
    const normalized = common.normalizePathAlloc(std.heap.page_allocator, source_entry) catch return false;
    defer std.heap.page_allocator.free(normalized);

    if (normalized.len == 0) return false;
    if (std.mem.indexOf(u8, normalized, "//") != null or std.mem.indexOfScalar(u8, normalized, ':') != null) {
        return false;
    }
    return std.mem.eql(u8, normalized, relative_filepath) or
        std.mem.eql(u8, normalized, basename) or
        (normalized.len > basename.len and
            normalized[normalized.len - basename.len - 1] == '/' and
            std.mem.eql(u8, normalized[normalized.len - basename.len ..], basename));
}

fn globMatchesFile(patterns: [][]u8, relative_filepath: []const u8, basename: []const u8) bool {
    for (patterns) |pattern| {
        if (globPatternMatches(pattern, relative_filepath) or globPatternMatches(pattern, basename)) {
            return true;
        }
    }
    return false;
}

fn globPatternMatches(pattern: []const u8, value: []const u8) bool {
    return matchGlob(pattern, value);
}

fn matchGlob(pattern: []const u8, value: []const u8) bool {
    if (pattern.len == 0) return value.len == 0;

    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '*') {
        if (matchGlob(pattern[2..], value)) return true;
        if (value.len > 0) {
            return matchGlob(pattern, value[1..]);
        }
        return false;
    }

    if (pattern[0] == '*') {
        if (matchGlob(pattern[1..], value)) return true;
        if (value.len > 0 and value[0] != '/') {
            return matchGlob(pattern, value[1..]);
        }
        return false;
    }

    if (pattern[0] == '?') {
        return value.len > 0 and matchGlob(pattern[1..], value[1..]);
    }

    return value.len > 0 and pattern[0] == value[0] and matchGlob(pattern[1..], value[1..]);
}

fn sourceEntriesAreRelatedToFile(
    allocator: std.mem.Allocator,
    source_entries: [][]u8,
    filepath: []const u8,
) bool {
    const current_stem = normalizeRelatedStemAlloc(allocator, filepath) catch return false;
    defer allocator.free(current_stem);
    if (current_stem.len == 0) return false;

    for (source_entries) |source_entry| {
        const source_stem = normalizeRelatedStemAlloc(allocator, source_entry) catch continue;
        defer allocator.free(source_stem);
        if (source_stem.len > 0 and std.mem.eql(u8, source_stem, current_stem)) {
            return true;
        }
    }
    return false;
}

fn normalizeRelatedStemAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var stem = std.ArrayList(u8).empty;
    defer stem.deinit(allocator);

    const base = std.fs.path.stem(std.fs.path.basename(name));
    for (base) |ch| {
        try stem.append(allocator, std.ascii.toLower(ch));
    }

    var value = stem.items;
    value = trimPrefix(value, "test.");
    value = trimPrefix(value, "test_");
    value = trimPrefix(value, "test-");
    value = trimPrefix(value, "test");
    value = trimSuffix(value, ".tests");
    value = trimSuffix(value, "_tests");
    value = trimSuffix(value, "-tests");
    value = trimSuffix(value, "tests");
    value = trimSuffix(value, ".test");
    value = trimSuffix(value, "_test");
    value = trimSuffix(value, "-test");
    value = trimSuffix(value, "test");
    value = trimSuffix(value, ".specs");
    value = trimSuffix(value, "_specs");
    value = trimSuffix(value, "-specs");
    value = trimSuffix(value, "specs");
    value = trimSuffix(value, ".spec");
    value = trimSuffix(value, "_spec");
    value = trimSuffix(value, "-spec");
    value = trimSuffix(value, "spec");

    return allocator.dupe(u8, value);
}

fn trimPrefix(value: []u8, prefix: []const u8) []u8 {
    if (std.mem.startsWith(u8, value, prefix)) {
        return value[prefix.len..];
    }
    return value;
}

fn trimSuffix(value: []u8, suffix: []const u8) []u8 {
    if (std.mem.endsWith(u8, value, suffix)) {
        return value[0 .. value.len - suffix.len];
    }
    return value;
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
    defer freeOwnedTargets(allocator, targets);

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
