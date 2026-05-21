const std = @import("std");
const pathing = @import("../../pathing.zig");
const project_common = @import("../../project/core/common.zig");

pub fn shouldPreferProjectRunner(
    allocator: std.mem.Allocator,
    path: []const u8,
    context_path: []const u8,
    project_root: ?[]const u8,
) !bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return shouldPreferProjectRunnerWithIO(threaded.io(), allocator, path, context_path, project_root);
}

pub fn shouldPreferProjectRunnerWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    context_path: []const u8,
    project_root: ?[]const u8,
) !bool {
    const root = try findBuildRootAllocWithIO(io, allocator, context_path, project_root, 12) orelse return false;
    defer allocator.free(root);

    const contents = project_common.readFileAllocWithIO(io, allocator, path) catch return false;
    defer allocator.free(contents);

    return sourceRequiresProjectModules(contents);
}

pub fn findBuildRootAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
    max_up: usize,
) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findBuildRootAllocWithIO(threaded.io(), allocator, path, project_root, max_up);
}

pub fn findBuildRootAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
    max_up: usize,
) !?[]u8 {
    if (project_root) |root| {
        if (root.len > 0 and try pathHasFileWithIO(io, allocator, root, "build.zig")) {
            return @as(?[]u8, try allocator.dupe(u8, root));
        }
    }

    var current = try allocator.dupe(u8, pathing.dirOrDot(path));
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (try pathHasFileWithIO(io, allocator, current, "build.zig")) {
            return @as(?[]u8, try allocator.dupe(u8, current));
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return null;
}

fn pathHasFile(root: []const u8, name: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return pathHasFileWithIO(threaded.io(), std.heap.page_allocator, root, name) catch false;
}

fn pathHasFileWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8, name: []const u8) !bool {
    const full_path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(full_path);

    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
}

pub fn sourceRequiresProjectModules(contents: []const u8) bool {
    var i: usize = 0;
    var line_start = true;
    var only_leading_whitespace = true;

    while (i < contents.len) {
        const ch = contents[i];

        if (ch == '\n') {
            line_start = true;
            only_leading_whitespace = true;
            i += 1;
            continue;
        }

        if (line_start and only_leading_whitespace and (ch == ' ' or ch == '\t' or ch == '\r')) {
            i += 1;
            continue;
        }

        if (line_start and only_leading_whitespace and ch == '\\' and i + 1 < contents.len and contents[i + 1] == '\\') {
            i = skipToLineEnd(contents, i + 2);
            line_start = false;
            only_leading_whitespace = false;
            continue;
        }

        line_start = false;
        only_leading_whitespace = false;

        if (ch == '/' and i + 1 < contents.len and contents[i + 1] == '/') {
            i = skipToLineEnd(contents, i + 2);
            continue;
        }

        if (ch == '"') {
            i = skipQuoted(contents, i + 1, '"');
            continue;
        }

        if (ch == '\'') {
            i = skipQuoted(contents, i + 1, '\'');
            continue;
        }

        if (std.mem.startsWith(u8, contents[i..], "@import(\"")) {
            const import_start = i + "@import(\"".len;
            const rest = contents[import_start..];
            const end = std.mem.findScalar(u8, rest, '"') orelse return false;
            const name = rest[0..end];
            if (isProjectModuleImport(name)) return true;
            i = import_start + end + 1;
            continue;
        }

        i += 1;
    }

    return false;
}

fn isProjectModuleImport(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "std")) return false;
    if (std.mem.eql(u8, name, "builtin")) return false;
    if (std.mem.eql(u8, name, "root")) return false;
    if (std.mem.endsWith(u8, name, ".zig")) return false;
    return true;
}

fn skipToLineEnd(contents: []const u8, start: usize) usize {
    var i = start;
    while (i < contents.len and contents[i] != '\n') : (i += 1) {}
    return i;
}

fn skipQuoted(contents: []const u8, start: usize, quote: u8) usize {
    var i = start;
    while (i < contents.len) : (i += 1) {
        if (contents[i] == '\\' and i + 1 < contents.len) {
            i += 1;
            continue;
        }
        if (contents[i] == quote) return i + 1;
        if (contents[i] == '\n') return i;
    }
    return i;
}

test "sourceRequiresProjectModules ignores comments and string literals" {
    const contents =
        \\// @import("zig")
        \\const text = "@import(\"demo\")";
        \\const c = '@';
        \\pub fn main() void {}
    ;

    try std.testing.expect(!sourceRequiresProjectModules(contents));
}

test "sourceRequiresProjectModules ignores multiline string lines" {
    const contents =
        \\const text =
        \\    \\@import("zig")
        \\;
        \\pub fn main() void {}
    ;

    try std.testing.expect(!sourceRequiresProjectModules(contents));
}

test "sourceRequiresProjectModules detects build-defined module imports" {
    const contents =
        \\const zig = @import("zig");
        \\const root = @import("root");
    ;

    try std.testing.expect(sourceRequiresProjectModules(contents));
}

test "findBuildRootAlloc walks parents from relative path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });

    const repo_relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path[0..]});
    defer allocator.free(repo_relative);
    const filepath_relative = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{repo_relative});
    defer allocator.free(filepath_relative);

    const root = try findBuildRootAlloc(allocator, filepath_relative, null, 12);
    defer if (root) |value| allocator.free(value);

    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings(repo_relative, root.?);
}
