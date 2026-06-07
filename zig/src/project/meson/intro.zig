const std = @import("std");
const build_common = @import("../../build/common.zig");
const common = @import("../core/common.zig");
const project_io = @import("../core/io.zig");
const pathing = @import("../../pathing.zig");
const parse = @import("parse.zig");

pub fn parseTargets(
    allocator: std.mem.Allocator,
    meson_build_path: []const u8,
    match_path: ?[]const u8,
) !?[]parse.Target {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return parseTargetsWithIO(threaded.io(), allocator, meson_build_path, match_path);
}

pub fn parseTargetsWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    meson_build_path: []const u8,
    match_path: ?[]const u8,
) !?[]parse.Target {
    const root = pathing.dirOrDot(meson_build_path);
    const build_dir = (try build_common.discoverMesonBuildDirAllocWithIO(io, allocator, root)) orelse return null;
    defer allocator.free(build_dir);

    const intro_path = try std.fs.path.join(allocator, &.{ root, build_dir, "meson-info", "intro-targets.json" });
    defer allocator.free(intro_path);
    if (!project_io.pathExistsWithIO(io, intro_path)) return null;

    const normalized_root = try common.normalizePathAlloc(allocator, root);
    defer allocator.free(normalized_root);

    var normalized_match_path: ?[]u8 = null;
    defer if (normalized_match_path) |value| allocator.free(value);
    var relative_match_path: ?[]u8 = null;
    defer if (relative_match_path) |value| allocator.free(value);
    var basename: ?[]u8 = null;
    defer if (basename) |value| allocator.free(value);

    if (match_path) |raw_match_path| {
        normalized_match_path = try common.normalizePathAlloc(allocator, raw_match_path);
        relative_match_path = try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized_match_path.?);
        basename = try allocator.dupe(u8, std.fs.path.basename(normalized_match_path.?));
    }

    const contents = try common.readFileAllocWithIO(io, allocator, intro_path);
    defer allocator.free(contents);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return null;

    var targets: std.ArrayList(parse.Target) = .empty;
    errdefer {
        for (targets.items) |item| {
            allocator.free(item.name);
            if (item.artifact_path) |artifact_path| allocator.free(artifact_path);
        }
        targets.deinit(allocator);
    }

    for (parsed.value.array.items) |target_value| {
        const target = try parseExecutableTargetAlloc(
            allocator,
            target_value,
            normalized_root,
            relative_match_path,
            basename,
        ) orelse continue;
        try appendOrMergeTarget(allocator, &targets, target);
    }

    if (targets.items.len == 0) return null;
    return try targets.toOwnedSlice(allocator);
}

fn appendOrMergeTarget(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(parse.Target),
    incoming: parse.Target,
) !void {
    for (targets.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, incoming.name)) continue;

        existing.matched = existing.matched or incoming.matched;
        if (existing.artifact_path == null and incoming.artifact_path != null) {
            existing.artifact_path = incoming.artifact_path;
        } else if (incoming.artifact_path) |artifact_path| {
            allocator.free(artifact_path);
        }
        allocator.free(incoming.name);
        return;
    }

    try targets.append(allocator, incoming);
}

fn parseExecutableTargetAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    normalized_root: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
) !?parse.Target {
    const target_type = getStringField(value, "type") orelse return null;
    if (!std.mem.eql(u8, target_type, "executable")) return null;

    const name = getStringField(value, "name") orelse return null;
    const matched = try targetMatches(allocator, value, normalized_root, relative_match_path, basename);
    const artifact_path = try extractArtifactPathAlloc(allocator, value, normalized_root);
    errdefer if (artifact_path) |path| allocator.free(path);

    return .{
        .name = try allocator.dupe(u8, name),
        .matched = matched,
        .artifact_path = artifact_path,
    };
}

fn targetMatches(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    normalized_root: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
) !bool {
    if (relative_match_path == null and basename == null) return false;

    const target_sources = getArrayField(value, "target_sources") orelse return false;
    for (target_sources) |entry| {
        const sources = getArrayField(entry, "sources") orelse continue;
        for (sources) |source_value| {
            if (source_value != .string) continue;
            const relative_source = try normalizeToRelativeRootAlloc(allocator, normalized_root, source_value.string);
            defer allocator.free(relative_source);

            if (relative_match_path) |match_value| {
                if (std.mem.eql(u8, relative_source, match_value)) return true;
            }
            if (basename) |basename_value| {
                if (std.mem.eql(u8, relative_source, basename_value)) return true;
                if (std.mem.endsWith(u8, relative_source, basename_value)) {
                    const prefix_len = relative_source.len - basename_value.len;
                    if (prefix_len > 0 and relative_source[prefix_len - 1] == '/') return true;
                }
            }
        }
    }

    return false;
}

fn extractArtifactPathAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    normalized_root: []const u8,
) !?[]u8 {
    const filenames = getArrayField(value, "filename") orelse return null;
    for (filenames) |filename_value| {
        if (filename_value != .string) continue;
        const normalized = try common.normalizePathAlloc(allocator, filename_value.string);
        defer allocator.free(normalized);
        if (std.mem.startsWith(u8, normalized, normalized_root)) {
            const relative = try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized);
            defer allocator.free(relative);
            return try std.fmt.allocPrint(allocator, "./{s}", .{relative});
        }
        return try allocator.dupe(u8, normalized);
    }
    return null;
}

fn normalizeToRelativeRootAlloc(
    allocator: std.mem.Allocator,
    normalized_root: []const u8,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const normalized = try common.normalizePathAlloc(allocator, path);
        defer allocator.free(normalized);
        return try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized);
    }
    return try common.normalizePathAlloc(allocator, path);
}

fn pathExists(path: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return project_io.pathExistsWithIO(threaded.io(), path);
}

fn getField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn getStringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field_value = getField(value, name) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn getArrayField(value: std.json.Value, name: []const u8) ?[]const std.json.Value {
    const field_value = getField(value, name) orelse return null;
    if (field_value != .array) return null;
    return field_value.array.items;
}
