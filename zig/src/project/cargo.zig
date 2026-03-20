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
    cargo_toml_path: []const u8,
    match_path: ?[]const u8,
) ![]Target {
    const root = std.fs.path.dirname(cargo_toml_path) orelse "";
    const normalized_root = try common.normalizePathAlloc(allocator, root);
    defer allocator.free(normalized_root);

    var relative_match_path: ?[]u8 = null;
    defer if (relative_match_path) |value| allocator.free(value);
    if (match_path) |raw_match_path| {
        const normalized_match = try common.normalizePathAlloc(allocator, raw_match_path);
        defer allocator.free(normalized_match);
        relative_match_path = try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized_match);
    }

    var targets: std.ArrayList(Target) = .empty;
    errdefer {
        for (targets.items) |item| allocator.free(item.name);
        targets.deinit(allocator);
    }

    const package_name = parsePackageName(contents);
    try parseExplicitBins(allocator, contents, relative_match_path, &targets);
    try addImplicitBinTargets(allocator, package_name, relative_match_path, &targets);

    return try targets.toOwnedSlice(allocator);
}

fn parseExplicitBins(
    allocator: std.mem.Allocator,
    contents: []const u8,
    relative_match_path: ?[]const u8,
    targets: *std.ArrayList(Target),
) !void {
    var capture: ?std.ArrayList(u8) = null;
    defer if (capture) |*list| list.deinit(allocator);
    var in_bin_block = false;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        const trimmed = common.trimSpaces(line);
        const is_section = trimmed.len >= 3 and trimmed[0] == '[';
        if (std.mem.eql(u8, trimmed, "[[bin]]")) {
            if (capture != null) {
                try commitBinBlock(allocator, capture.?.items, relative_match_path, targets);
                capture.?.deinit(allocator);
                capture = null;
            }
            in_bin_block = true;
            capture = std.ArrayList(u8).empty;
            continue;
        }
        if (is_section and in_bin_block) {
            if (capture != null) {
                try commitBinBlock(allocator, capture.?.items, relative_match_path, targets);
                capture.?.deinit(allocator);
                capture = null;
            }
            in_bin_block = false;
        }
        if (in_bin_block and capture != null) {
            try capture.?.appendSlice(allocator, line);
            try capture.?.append(allocator, '\n');
        }
    }

    if (in_bin_block and capture != null) {
        try commitBinBlock(allocator, capture.?.items, relative_match_path, targets);
        capture.?.deinit(allocator);
        capture = null;
    }
}

fn commitBinBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    relative_match_path: ?[]const u8,
    targets: *std.ArrayList(Target),
) !void {
    const name = parseNamedString(block, "name") orelse return;
    if (name.len == 0) return;

    var matched = false;
    if (relative_match_path) |relative_path| {
        if (parseNamedString(block, "path")) |explicit_path| {
            matched = std.mem.eql(u8, common.trimSpaces(explicit_path), relative_path);
        } else {
            var inferred_path_buf: [512]u8 = undefined;
            const inferred_path = try std.fmt.bufPrint(&inferred_path_buf, "src/bin/{s}.rs", .{name});
            matched = std.mem.eql(u8, inferred_path, relative_path);
        }
    }

    try addOrMergeTarget(allocator, targets, name, matched);
}

fn addImplicitBinTargets(
    allocator: std.mem.Allocator,
    package_name: ?[]const u8,
    relative_match_path: ?[]const u8,
    targets: *std.ArrayList(Target),
) !void {
    const relative_path = relative_match_path orelse return;

    if (package_name) |pkg_name| {
        if (std.mem.eql(u8, relative_path, "src/main.rs")) {
            try addOrMergeTarget(allocator, targets, pkg_name, true);
        }
    }

    if (std.mem.startsWith(u8, relative_path, "src/bin/") and std.mem.endsWith(u8, relative_path, ".rs")) {
        const suffix = relative_path["src/bin/".len .. relative_path.len - ".rs".len];
        if (std.mem.indexOfScalar(u8, suffix, '/') == null and suffix.len > 0) {
            try addOrMergeTarget(allocator, targets, suffix, true);
        }
    }
}

fn addOrMergeTarget(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(Target),
    name: []const u8,
    matched: bool,
) !void {
    for (targets.items) |*item| {
        if (std.mem.eql(u8, item.name, name)) {
            item.matched = item.matched or matched;
            return;
        }
    }
    try targets.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .matched = matched,
    });
}

fn parsePackageName(contents: []const u8) ?[]const u8 {
    var in_package = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = stripHashComment(common.stripTrailingCR(raw_line));
        const trimmed = common.trimSpaces(line);
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[') {
            in_package = std.mem.eql(u8, trimmed, "[package]");
            continue;
        }
        if (!in_package) continue;
        if (parseNamedString(trimmed, "name")) |name| {
            if (name.len > 0) return name;
        }
    }
    return null;
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

fn stripHashComment(line: []const u8) []const u8 {
    const hash_idx = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash_idx];
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn isIdentContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

test "parse cargo bins" {
    const allocator = std.testing.allocator;
    const contents =
        \\[package]
        \\name = "demo"
        \\
        \\[[bin]]
        \\name = "tool"
        \\path = "tools/tool.rs"
    ;

    const targets = try parseTargets(allocator, contents, "/tmp/rustproj/Cargo.toml", "/tmp/rustproj/src/main.rs");
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("tool", targets[0].name);
    try std.testing.expect(!targets[0].matched);
    try std.testing.expectEqualStrings("demo", targets[1].name);
    try std.testing.expect(targets[1].matched);
}

test "infer src bin target from file path" {
    const allocator = std.testing.allocator;
    const contents =
        \\[package]
        \\name = "demo"
    ;

    const targets = try parseTargets(allocator, contents, "/tmp/rustproj/Cargo.toml", "/tmp/rustproj/src/bin/foo.rs");
    defer freeOwnedTargets(allocator, targets);

    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("foo", targets[0].name);
    try std.testing.expect(targets[0].matched);
}
