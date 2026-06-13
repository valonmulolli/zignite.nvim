const std = @import("std");
const common = @import("../core/common.zig");
const model = @import("model.zig");
const pathing = @import("../../pathing.zig");

const Target = model.Target;
const CommandEntry = model.CommandEntry;
const CommandInfo = model.CommandInfo;

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

    const package_dir = pathing.dirOrDot(build_path);
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
        const command_suffix = try commandSuffixAlloc(allocator, package_path, item.name);
        defer allocator.free(command_suffix);

        const build_name = try std.fmt.allocPrint(allocator, "bazel-build-{s}", .{command_suffix});
        const build_command = std.fmt.allocPrint(allocator, "bazel build {s}", .{label}) catch |err| {
            allocator.free(build_name);
            return err;
        };
        try appendCommandEntry(allocator, &commands, build_name, build_command);

        if (item.supports_run) {
            const run_name = try std.fmt.allocPrint(allocator, "bazel-run-{s}", .{command_suffix});
            const run_command = std.fmt.allocPrint(allocator, "bazel run {s}", .{label}) catch |err| {
                allocator.free(run_name);
                return err;
            };
            try appendCommandEntry(allocator, &commands, run_name, run_command);
        }

        if (item.supports_test) {
            const test_name = try std.fmt.allocPrint(allocator, "bazel-test-{s}", .{command_suffix});
            const test_command = std.fmt.allocPrint(allocator, "bazel test {s}", .{label}) catch |err| {
                allocator.free(test_name);
                return err;
            };
            try appendCommandEntry(allocator, &commands, test_name, test_command);
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

fn commandSuffixAlloc(allocator: std.mem.Allocator, package_path: []const u8, target_name: []const u8) ![]u8 {
    var suffix: std.ArrayList(u8) = .empty;
    defer suffix.deinit(allocator);

    if (package_path.len > 0) {
        try appendSanitizedPart(allocator, &suffix, package_path);
        if (suffix.items.len > 0) {
            try suffix.append(allocator, '-');
        }
    }
    try appendSanitizedPart(allocator, &suffix, target_name);
    return try suffix.toOwnedSlice(allocator);
}

fn appendSanitizedPart(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try list.append(allocator, ch);
            continue;
        }
        if (list.items.len == 0 or list.items[list.items.len - 1] != '-') {
            try list.append(allocator, '-');
        }
    }
    while (list.items.len > 0 and list.items[list.items.len - 1] == '-') {
        _ = list.pop();
    }
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
    if (std.mem.find(u8, normalized, "//") != null or std.mem.findScalar(u8, normalized, ':') != null) {
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
    return matchGlobDepth(pattern, value, 0);
}

fn matchGlobDepth(pattern: []const u8, value: []const u8, depth: usize) bool {
    if (depth > 200) return false;
    if (pattern.len == 0) return value.len == 0;

    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '*') {
        if (matchGlobDepth(pattern[2..], value, depth + 1)) return true;
        if (value.len > 0) {
            return matchGlobDepth(pattern, value[1..], depth + 1);
        }
        return false;
    }

    if (pattern[0] == '*') {
        if (matchGlobDepth(pattern[1..], value, depth + 1)) return true;
        if (value.len > 0 and value[0] != '/') {
            return matchGlobDepth(pattern, value[1..], depth + 1);
        }
        return false;
    }

    if (pattern[0] == '?') {
        return value.len > 0 and matchGlobDepth(pattern[1..], value[1..], depth + 1);
    }

    return value.len > 0 and pattern[0] == value[0] and matchGlobDepth(pattern[1..], value[1..], depth + 1);
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
