const std = @import("std");
const common = @import("../core/common.zig");
const project_io = @import("../core/io.zig");

pub fn parseTargetsFromFileAlloc(
    allocator: std.mem.Allocator,
    makefile_path: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return parseTargetsFromFileAllocWithIO(threaded.io(), allocator, makefile_path, names);
}

pub fn parseTargetsFromFileAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    makefile_path: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    var visited: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &visited);
    try parseTargetsFromFileInner(io, allocator, makefile_path, names, &visited);
}

pub fn collectReferencedFilesFromFileAlloc(
    allocator: std.mem.Allocator,
    makefile_path: []const u8,
) ![][]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return collectReferencedFilesFromFileAllocWithIO(threaded.io(), allocator, makefile_path);
}

pub fn collectReferencedFilesFromFileAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    makefile_path: []const u8,
) ![][]u8 {
    var visited: std.ArrayList([]u8) = .empty;
    errdefer common.deinitOwnedNameList(allocator, &visited);

    try collectReferencedFilesInner(io, allocator, makefile_path, &visited);
    return try visited.toOwnedSlice(allocator);
}

fn parseTargetsFromFileInner(
    io: std.Io,
    allocator: std.mem.Allocator,
    makefile_path: []const u8,
    names: *std.ArrayList([]u8),
    visited: *std.ArrayList([]u8),
) !void {
    const normalized = try common.normalizePathAlloc(allocator, makefile_path);
    defer allocator.free(normalized);

    for (visited.items) |existing| {
        if (std.mem.eql(u8, existing, normalized)) return;
    }
    try appendOwnedName(allocator, visited, normalized);

    const contents = try common.readFileAllocWithIO(io, allocator, makefile_path);
    defer allocator.free(contents);
    try parseTargets(allocator, contents, names);

    const current_dir = std.fs.path.dirname(makefile_path) orelse ".";
    var includes = try collectIncludePathsAlloc(allocator, contents, current_dir);
    defer common.deinitOwnedNameList(allocator, &includes);

    for (includes.items) |include_path| {
        if (!project_io.pathExistsWithIO(io, include_path)) continue;
        try parseTargetsFromFileInner(io, allocator, include_path, names, visited);
    }
}

fn collectReferencedFilesInner(
    io: std.Io,
    allocator: std.mem.Allocator,
    makefile_path: []const u8,
    visited: *std.ArrayList([]u8),
) !void {
    const normalized = try common.normalizePathAlloc(allocator, makefile_path);
    defer allocator.free(normalized);

    for (visited.items) |existing| {
        if (std.mem.eql(u8, existing, normalized)) return;
    }
    try appendOwnedName(allocator, visited, normalized);

    const contents = try common.readFileAllocWithIO(io, allocator, makefile_path);
    defer allocator.free(contents);

    const current_dir = std.fs.path.dirname(makefile_path) orelse ".";
    var includes = try collectIncludePathsAlloc(allocator, contents, current_dir);
    defer common.deinitOwnedNameList(allocator, &includes);

    for (includes.items) |include_path| {
        if (!project_io.pathExistsWithIO(io, include_path)) continue;
        try collectReferencedFilesInner(io, allocator, include_path, visited);
    }
}

fn appendOwnedName(allocator: std.mem.Allocator, names: *std.ArrayList([]u8), name: []const u8) !void {
    const owned_name = try allocator.dupe(u8, name);
    names.append(allocator, owned_name) catch |err| {
        allocator.free(owned_name);
        return err;
    };
}

pub fn parseTargets(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    if (isCmakeGeneratedMakefile(contents)) {
        return;
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.stripTrailingCR(raw_line);
        const trimmed = common.trimSpaces(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (line.len > 0 and line[0] == '\t') continue;
        if (looksLikeVariableAssignment(trimmed)) continue;

        const colon_idx = std.mem.findScalar(u8, trimmed, ':') orelse continue;
        const target_segment = common.trimSpaces(trimmed[0..colon_idx]);
        if (target_segment.len == 0) continue;

        if (std.mem.eql(u8, target_segment, ".PHONY")) {
            var phony_it = std.mem.tokenizeScalar(u8, common.trimSpaces(trimmed[colon_idx + 1 ..]), ' ');
            while (phony_it.next()) |raw_target| {
                const target = common.trimSpaces(raw_target);
                if (!isValidMakeTarget(target)) continue;
                try common.pushUniqueName(allocator, names, target);
            }
            continue;
        }

        var target_it = std.mem.tokenizeScalar(u8, target_segment, ' ');
        while (target_it.next()) |raw_target| {
            const target = common.trimSpaces(raw_target);
            if (!isValidMakeTarget(target)) continue;
            try common.pushUniqueName(allocator, names, target);
        }
    }
}

fn isCmakeGeneratedMakefile(contents: []const u8) bool {
    return std.mem.find(u8, contents, "CMAKE generated file: DO NOT EDIT!") != null or std.mem.find(u8, contents, "Generated by \"Unix Makefiles\" Generator") != null;
}

fn looksLikeVariableAssignment(line: []const u8) bool {
    const eq_idx = std.mem.findScalar(u8, line, '=') orelse return false;
    if (eq_idx == 0) return false;
    const prefix = common.trimSpaces(line[0..eq_idx]);
    if (prefix.len == 0) return false;
    const last = prefix[prefix.len - 1];
    if (last == ':' or last == '+' or last == '?') {
        return isIdentifierPrefix(common.trimSpaces(prefix[0 .. prefix.len - 1]));
    }
    return isIdentifierPrefix(prefix);
}

fn isIdentifierPrefix(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-')) {
            return false;
        }
    }
    return true;
}

fn collectIncludePathsAlloc(
    allocator: std.mem.Allocator,
    contents: []const u8,
    current_dir: []const u8,
) !std.ArrayList([]u8) {
    var includes: std.ArrayList([]u8) = .empty;
    errdefer common.deinitOwnedNameList(allocator, &includes);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = common.stripTrailingCR(raw_line);
        const trimmed = common.trimSpaces(stripHashComment(line));
        if (trimmed.len == 0) continue;

        const remainder = if (std.mem.startsWith(u8, trimmed, "include "))
            trimmed["include ".len..]
        else if (std.mem.startsWith(u8, trimmed, "-include "))
            trimmed["-include ".len..]
        else if (std.mem.startsWith(u8, trimmed, "sinclude "))
            trimmed["sinclude ".len..]
        else
            continue;

        var path_it = std.mem.tokenizeScalar(u8, remainder, ' ');
        while (path_it.next()) |raw_value| {
            const value = common.trimSpaces(raw_value);
            if (!isSupportedIncludePath(value)) continue;

            const include_path = if (std.fs.path.isAbsolute(value))
                try common.normalizePathAlloc(allocator, value)
            else blk: {
                const joined = try std.fs.path.join(allocator, &.{ current_dir, value });
                defer allocator.free(joined);
                break :blk try common.normalizePathAlloc(allocator, joined);
            };
            errdefer allocator.free(include_path);
            try common.pushUniqueName(allocator, &includes, include_path);
            allocator.free(include_path);
        }
    }

    return includes;
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

fn isSupportedIncludePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.findAny(u8, path, "$*?") != null) return false;
    return true;
}

fn pathExists(path: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return project_io.pathExistsWithIO(threaded.io(), path);
}

fn isValidMakeTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    if (std.mem.eql(u8, target, "|")) return false;
    if (target[0] == '.') return false;
    if (std.mem.findScalar(u8, target, '%') != null) return false;
    if (std.mem.find(u8, target, "$(") != null) return false;
    return true;
}

test "parse make targets" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    try parseTargets(
        allocator,
        "build: test\n\t@echo ok\nVAR := value\nbench:\n",
        &names,
    );

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("build", names.items[0]);
    try std.testing.expectEqualStrings("bench", names.items[1]);
}

test "skip cmake generated makefile" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    try parseTargets(allocator,
        \\# CMAKE generated file: DO NOT EDIT!
        \\all:
    , &names);
    try std.testing.expectEqual(@as(usize, 0), names.items.len);
}

test "parse phony make targets" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTargets(
        allocator,
        ".PHONY: serve verify format\n",
        &names,
    );

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("serve", names.items[0]);
    try std.testing.expectEqualStrings("verify", names.items[1]);
    try std.testing.expectEqualStrings("format", names.items[2]);
}

test "parse make targets follows local includes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data =
        \\include targets.mk
        \\.PHONY: all
        \\all:
        \\\t@echo all
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "targets.mk", .data =
        \\.PHONY: serve verify
        \\serve:
        \\\t@echo serve
        \\verify:
        \\\t@echo verify
    });

    const makefile_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Makefile", allocator);
    defer allocator.free(makefile_path);

    var names: std.ArrayList([]u8) = .empty;
    defer common.deinitOwnedNameList(allocator, &names);

    try parseTargetsFromFileAlloc(allocator, makefile_path, &names);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("all", names.items[0]);
    try std.testing.expectEqualStrings("serve", names.items[1]);
    try std.testing.expectEqualStrings("verify", names.items[2]);
}

test "collectReferencedFilesFromFileAlloc includes local includes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data =
        \\include nested/targets.mk
        \\all:
        \\\t@echo all
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/targets.mk", .data =
        \\serve:
        \\\t@echo serve
    });

    const makefile_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Makefile", allocator);
    defer allocator.free(makefile_path);
    const included_path = try tmp.dir.realPathFileAlloc(std.testing.io, "nested/targets.mk", allocator);
    defer allocator.free(included_path);

    const files = try collectReferencedFilesFromFileAlloc(allocator, makefile_path);
    defer common.freeOwnedNameList(allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings(makefile_path, files[0]);
    try std.testing.expectEqualStrings(included_path, files[1]);
}
