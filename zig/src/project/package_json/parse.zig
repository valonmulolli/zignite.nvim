const std = @import("std");
const common = @import("../core/common.zig");

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

pub fn formatInstallCommandAlloc(allocator: std.mem.Allocator, package_manager: []const u8) ![]u8 {
    if (std.mem.eql(u8, package_manager, "bun")) {
        return allocator.dupe(u8, "bun install");
    }
    if (std.mem.eql(u8, package_manager, "yarn")) {
        return allocator.dupe(u8, "yarn install");
    }
    if (std.mem.eql(u8, package_manager, "pnpm")) {
        return allocator.dupe(u8, "pnpm install");
    }
    return allocator.dupe(u8, "npm install");
}

pub fn detectPackageManager(
    allocator: std.mem.Allocator,
    root: []const u8,
    contents: []const u8,
) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch null;
    defer if (parsed) |value| value.deinit();

    if (parsed) |value| {
        if (value.value == .object) {
            if (value.value.object.get("packageManager")) |package_manager| {
                if (package_manager == .string) {
                    const manager_name = std.mem.sliceTo(package_manager.string, '@');
                    if (std.mem.eql(u8, manager_name, "npm")) return "npm";
                    if (std.mem.eql(u8, manager_name, "pnpm")) return "pnpm";
                    if (std.mem.eql(u8, manager_name, "yarn")) return "yarn";
                    if (std.mem.eql(u8, manager_name, "bun")) return "bun";
                }
            }
        }
    }

    if (pathExists(allocator, root, "bun.lockb") or pathExists(allocator, root, "bun.lock")) return "bun";
    if (pathExists(allocator, root, "pnpm-lock.yaml")) return "pnpm";
    if (pathExists(allocator, root, "yarn.lock")) return "yarn";
    return "npm";
}

pub fn selectLiveScriptName(names: []const []const u8) ?[]const u8 {
    const priority = [_][]const u8{ "live", "dev", "watch", "serve", "start", "preview" };
    for (priority) |candidate| {
        for (names) |name| {
            if (std.mem.eql(u8, name, candidate)) return candidate;
        }
    }
    return null;
}

fn pathExists(allocator: std.mem.Allocator, root: []const u8, filename: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ root, filename }) catch return false;
    defer allocator.free(path);
    return std.fs.cwd().access(path, .{}) == void{};
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

test "format install command respects package manager" {
    const allocator = std.testing.allocator;

    const npm = try formatInstallCommandAlloc(allocator, "npm");
    defer allocator.free(npm);
    try std.testing.expectEqualStrings("npm install", npm);

    const pnpm = try formatInstallCommandAlloc(allocator, "pnpm");
    defer allocator.free(pnpm);
    try std.testing.expectEqualStrings("pnpm install", pnpm);

    const yarn = try formatInstallCommandAlloc(allocator, "yarn");
    defer allocator.free(yarn);
    try std.testing.expectEqualStrings("yarn install", yarn);
}

test "select live script prefers runtime-oriented scripts" {
    const names = [_][]const u8{ "build", "start", "dev" };
    try std.testing.expectEqualStrings("dev", selectLiveScriptName(&names).?);

    const explicit_live = [_][]const u8{ "start", "live" };
    try std.testing.expectEqualStrings("live", selectLiveScriptName(&explicit_live).?);

    const missing = [_][]const u8{ "build", "lint" };
    try std.testing.expect(selectLiveScriptName(&missing) == null);
}

test "detect package manager prefers packageManager field" {
    try std.testing.expectEqualStrings(
        "yarn",
        try detectPackageManager(
            std.testing.allocator,
            "/tmp/unused",
            \\{"packageManager":"yarn@4.6.0"}
        ),
    );
}

test "detect package manager falls back to lockfiles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "pnpm-lock.yaml", .data = "lockfileVersion: '9.0'" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try std.testing.expectEqualStrings("pnpm", try detectPackageManager(std.testing.allocator, root, "{}"));
}
