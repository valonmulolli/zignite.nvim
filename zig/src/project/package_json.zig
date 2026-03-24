const std = @import("std");
const common = @import("core/common.zig");

pub fn formatScriptCommandAlloc(
    allocator: std.mem.Allocator,
    package_manager: []const u8,
    script_name: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, package_manager, "bun")) {
        return std.fmt.allocPrint(allocator, "bun run {s}", .{script_name});
    }
    if (std.mem.eql(u8, package_manager, "yarn")) {
        return std.fmt.allocPrint(allocator, "yarn {s}", .{script_name});
    }
    if (std.mem.eql(u8, package_manager, "pnpm")) {
        if (std.mem.eql(u8, script_name, "start") or std.mem.eql(u8, script_name, "test")) {
            return std.fmt.allocPrint(allocator, "pnpm {s}", .{script_name});
        }
        return std.fmt.allocPrint(allocator, "pnpm run {s}", .{script_name});
    }
    if (std.mem.eql(u8, script_name, "start") or std.mem.eql(u8, script_name, "test")) {
        return std.fmt.allocPrint(allocator, "npm {s}", .{script_name});
    }
    return std.fmt.allocPrint(allocator, "npm run {s}", .{script_name});
}

pub fn parseScripts(
    allocator: std.mem.Allocator,
    contents: []const u8,
    names: *std.ArrayList([]u8),
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const scripts = root.object.get("scripts") orelse return;
    if (scripts != .object) return;

    var it = scripts.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try common.pushUniqueName(allocator, names, entry.key_ptr.*);
    }
}

test "parse package scripts" {
    const allocator = std.testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    try parseScripts(
        allocator,
        \\{"scripts":{"dev":"vite","build":"vite build","test":"vitest"}}
    , &names);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
}

test "format package script command respects package manager" {
    const allocator = std.testing.allocator;

    const npm = try formatScriptCommandAlloc(allocator, "npm", "lint");
    defer allocator.free(npm);
    try std.testing.expectEqualStrings("npm run lint", npm);

    const pnpm = try formatScriptCommandAlloc(allocator, "pnpm", "test");
    defer allocator.free(pnpm);
    try std.testing.expectEqualStrings("pnpm test", pnpm);

    const yarn = try formatScriptCommandAlloc(allocator, "yarn", "dev");
    defer allocator.free(yarn);
    try std.testing.expectEqualStrings("yarn dev", yarn);
}
