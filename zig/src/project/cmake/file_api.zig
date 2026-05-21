const std = @import("std");
const build_common = @import("../../build/common.zig");
const common = @import("../core/common.zig");
const pathing = @import("../../pathing.zig");
const parse = @import("parse.zig");

pub fn parseTargets(
    allocator: std.mem.Allocator,
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
) !?[]parse.Target {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return parseTargetsWithIO(threaded.io(), allocator, cmake_lists_path, match_path);
}

pub fn parseTargetsWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    cmake_lists_path: []const u8,
    match_path: ?[]const u8,
) !?[]parse.Target {
    const root = pathing.dirOrDot(cmake_lists_path);
    const build_dir = (try build_common.discoverCmakeBuildDirAllocWithIO(io, allocator, root)) orelse return null;
    defer allocator.free(build_dir);

    const reply_dir = try std.fs.path.join(allocator, &.{ root, build_dir, ".cmake", "api", "v1", "reply" });
    defer allocator.free(reply_dir);
    if (!pathExistsWithIO(io, reply_dir)) return null;

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

    const index_path = (try findReplyIndexAllocWithIO(io, allocator, reply_dir)) orelse return null;
    defer allocator.free(index_path);
    const codemodel_path = (try findCodeModelPathAlloc(io, allocator, reply_dir, index_path)) orelse return null;
    defer allocator.free(codemodel_path);

    var targets: std.ArrayList(parse.Target) = .empty;
    errdefer {
        for (targets.items) |item| {
            allocator.free(item.name);
            if (item.artifact_path) |artifact_path| allocator.free(artifact_path);
        }
        targets.deinit(allocator);
    }

    const codemodel_contents = try common.readFileAllocWithIO(io, allocator, codemodel_path);
    defer allocator.free(codemodel_contents);
    const codemodel = try std.json.parseFromSlice(std.json.Value, allocator, codemodel_contents, .{});
    defer codemodel.deinit();

    const configurations = getArrayField(codemodel.value, "configurations") orelse return null;
    for (configurations) |configuration_value| {
        const target_summaries = getArrayField(configuration_value, "targets") orelse continue;
        for (target_summaries) |summary_value| {
            const json_file = getStringField(summary_value, "jsonFile") orelse continue;
            const target_path = try std.fs.path.join(allocator, &.{ reply_dir, json_file });
            defer allocator.free(target_path);

            const target = try parseExecutableTargetAlloc(
                io,
                allocator,
                target_path,
                normalized_root,
                relative_match_path,
                basename,
            ) orelse continue;
            try appendOrMergeTarget(allocator, &targets, target);
        }
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
    io: std.Io,
    allocator: std.mem.Allocator,
    target_json_path: []const u8,
    normalized_root: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
) !?parse.Target {
    const contents = try common.readFileAllocWithIO(io, allocator, target_json_path);
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root_value = parsed.value;
    const target_type = getStringField(root_value, "type") orelse return null;
    if (!std.mem.eql(u8, target_type, "EXECUTABLE")) return null;

    const name = getStringField(root_value, "name") orelse return null;
    const source_dir = resolveTargetPathBaseAlloc(allocator, normalized_root, root_value, "source") catch null;
    defer if (source_dir) |value| allocator.free(value);
    const build_dir = resolveTargetPathBaseAlloc(allocator, normalized_root, root_value, "build") catch null;
    defer if (build_dir) |value| allocator.free(value);

    const matched = try targetMatches(
        allocator,
        root_value,
        source_dir,
        normalized_root,
        relative_match_path,
        basename,
    );
    const artifact_path = try extractArtifactPathAlloc(
        allocator,
        root_value,
        build_dir,
        normalized_root,
    );
    errdefer if (artifact_path) |path| allocator.free(path);

    return .{
        .name = try allocator.dupe(u8, name),
        .matched = matched,
        .artifact_path = artifact_path,
    };
}

fn targetMatches(
    allocator: std.mem.Allocator,
    root_value: std.json.Value,
    source_dir: ?[]const u8,
    normalized_root: []const u8,
    relative_match_path: ?[]const u8,
    basename: ?[]const u8,
) !bool {
    if (relative_match_path == null and basename == null) return false;

    const sources = getArrayField(root_value, "sources") orelse return false;
    for (sources) |source_value| {
        const raw_path = getStringField(source_value, "path") orelse continue;
        const relative_source = try resolveRelativePathAlloc(allocator, normalized_root, source_dir, raw_path);
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

    return false;
}

fn extractArtifactPathAlloc(
    allocator: std.mem.Allocator,
    root_value: std.json.Value,
    build_dir: ?[]const u8,
    normalized_root: []const u8,
) !?[]u8 {
    const artifacts = getArrayField(root_value, "artifacts") orelse return null;
    for (artifacts) |artifact_value| {
        const raw_path = getStringField(artifact_value, "path") orelse continue;
        const normalized_artifact = try resolveAbsoluteOrRelativeAlloc(allocator, build_dir, raw_path);
        defer allocator.free(normalized_artifact);
        return try renderRunPathAlloc(allocator, normalized_root, normalized_artifact);
    }
    return null;
}

fn resolveTargetPathBaseAlloc(
    allocator: std.mem.Allocator,
    normalized_root: []const u8,
    root_value: std.json.Value,
    field: []const u8,
) !?[]u8 {
    const paths_value = getField(root_value, "paths") orelse return null;
    const raw_path = getStringField(paths_value, field) orelse return null;
    return try resolveAbsoluteOrRelativeFromRootAlloc(allocator, normalized_root, raw_path);
}

fn resolveRelativePathAlloc(
    allocator: std.mem.Allocator,
    normalized_root: []const u8,
    base_dir: ?[]const u8,
    raw_path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) {
        const normalized = try common.normalizePathAlloc(allocator, raw_path);
        defer allocator.free(normalized);
        return try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized);
    }

    if (base_dir) |base| {
        const joined = try std.fs.path.join(allocator, &.{ base, raw_path });
        defer allocator.free(joined);
        const normalized = try common.normalizePathAlloc(allocator, joined);
        defer allocator.free(normalized);
        return try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized);
    }

    return try common.normalizePathAlloc(allocator, raw_path);
}

fn resolveAbsoluteOrRelativeAlloc(
    allocator: std.mem.Allocator,
    base_dir: ?[]const u8,
    raw_path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) {
        return try common.normalizePathAlloc(allocator, raw_path);
    }
    if (base_dir) |base| {
        const joined = try std.fs.path.join(allocator, &.{ base, raw_path });
        defer allocator.free(joined);
        return try common.normalizePathAlloc(allocator, joined);
    }
    return try common.normalizePathAlloc(allocator, raw_path);
}

fn resolveAbsoluteOrRelativeFromRootAlloc(
    allocator: std.mem.Allocator,
    normalized_root: []const u8,
    raw_path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) {
        return try common.normalizePathAlloc(allocator, raw_path);
    }

    const joined = try std.fs.path.join(allocator, &.{ normalized_root, raw_path });
    defer allocator.free(joined);
    return try common.normalizePathAlloc(allocator, joined);
}

fn renderRunPathAlloc(
    allocator: std.mem.Allocator,
    normalized_root: []const u8,
    normalized_artifact: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, normalized_artifact, normalized_root)) {
        const relative = try common.makeRelativeToRootAlloc(allocator, normalized_root, normalized_artifact);
        defer allocator.free(relative);
        return try std.fmt.allocPrint(allocator, "./{s}", .{relative});
    }

    return try allocator.dupe(u8, normalized_artifact);
}

fn findCodeModelPathAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    reply_dir: []const u8,
    index_path: []const u8,
) !?[]u8 {
    const contents = try common.readFileAllocWithIO(io, allocator, index_path);
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const reply = getField(parsed.value, "reply") orelse return null;
    if (reply != .object) return null;

    var it = reply.object.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, "codemodel-v2")) continue;
        const json_file = getStringField(entry.value_ptr.*, "jsonFile") orelse continue;
        return try std.fs.path.join(allocator, &.{ reply_dir, json_file });
    }

    return null;
}

fn findReplyIndexAllocWithIO(io: std.Io, allocator: std.mem.Allocator, reply_dir: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, reply_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "index-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        return try std.fs.path.join(allocator, &.{ reply_dir, entry.name });
    }

    return null;
}

fn pathExists(path: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return pathExistsWithIO(threaded.io(), path);
}

fn pathExistsWithIO(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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
