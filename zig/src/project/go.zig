const std = @import("std");
const common = @import("common.zig");
const go_mod = @import("go_mod.zig");
const go_work = @import("go_work.zig");

pub const Info = struct {
    module_name: ?[]u8 = null,
    primary_selector: ?[]u8 = null,
    primary_build: ?[]u8 = null,
    primary_run: ?[]u8 = null,
    primary_test: ?[]u8 = null,
};

pub fn freeOwnedInfo(allocator: std.mem.Allocator, info: Info) void {
    if (info.module_name) |value| allocator.free(value);
    if (info.primary_selector) |value| allocator.free(value);
    if (info.primary_build) |value| allocator.free(value);
    if (info.primary_run) |value| allocator.free(value);
    if (info.primary_test) |value| allocator.free(value);
}

pub fn parseInfo(
    allocator: std.mem.Allocator,
    contents: []const u8,
    project_path: []const u8,
    match_path: ?[]const u8,
) !Info {
    var info: Info = .{};

    const project_name = std.fs.path.basename(project_path);
    if (std.mem.eql(u8, project_name, "go.work")) {
        info.module_name = try parseWorkspaceModuleName(allocator, contents, project_path, match_path);
    } else {
        info.module_name = try go_mod.parseModuleName(allocator, contents);
    }

    if (match_path) |candidate| {
        const project_root = std.fs.path.dirname(project_path) orelse ".";
        const selector = try buildPackageSelectorAlloc(allocator, project_root, candidate);
        info.primary_selector = selector;

        if (!std.mem.eql(u8, selector, ".")) {
            const quoted_selector = try common.quoteShellArgAlloc(allocator, selector);
            defer allocator.free(quoted_selector);

            info.primary_build = try std.fmt.allocPrint(allocator, "go build {s}", .{quoted_selector});
            info.primary_run = try std.fmt.allocPrint(allocator, "go run {s}", .{quoted_selector});
            info.primary_test = try std.fmt.allocPrint(allocator, "go test {s}", .{quoted_selector});
        }
    }

    return info;
}

fn parseWorkspaceModuleName(
    allocator: std.mem.Allocator,
    contents: []const u8,
    go_work_path: []const u8,
    match_path: ?[]const u8,
) !?[]u8 {
    const items = try go_work.parseUses(allocator, contents, go_work_path, match_path);
    defer go_work.freeOwnedUses(allocator, items);

    var matched_root: ?[]const u8 = null;
    var first_root: ?[]const u8 = null;
    for (items) |item| {
        first_root = first_root orelse item.path;
        if (item.matched and matched_root == null) {
            matched_root = item.path;
        }
    }

    const module_root = matched_root orelse first_root orelse return null;
    const go_mod_path = try std.fs.path.join(allocator, &.{ module_root, "go.mod" });
    defer allocator.free(go_mod_path);

    const go_mod_contents = common.readFileAlloc(allocator, go_mod_path) catch return null;
    defer allocator.free(go_mod_contents);

    return try go_mod.parseModuleName(allocator, go_mod_contents);
}

fn buildPackageSelectorAlloc(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    match_path: []const u8,
) ![]u8 {
    const normalized_root = try common.normalizePathAlloc(allocator, project_root);
    defer allocator.free(normalized_root);

    const normalized_match = try common.normalizePathAlloc(allocator, match_path);
    defer allocator.free(normalized_match);

    const package_dir_slice = std.fs.path.dirname(normalized_match) orelse normalized_match;
    const normalized_package_dir = try common.normalizePathAlloc(allocator, package_dir_slice);
    defer allocator.free(normalized_package_dir);

    if (std.mem.eql(u8, normalized_package_dir, normalized_root)) {
        return try allocator.dupe(u8, ".");
    }

    if (normalized_root.len > 0 and
        normalized_package_dir.len > normalized_root.len and
        std.mem.startsWith(u8, normalized_package_dir, normalized_root) and
        normalized_package_dir[normalized_root.len] == '/')
    {
        return try std.fmt.allocPrint(allocator, "./{s}", .{normalized_package_dir[normalized_root.len + 1 ..]});
    }

    return try allocator.dupe(u8, ".");
}

test "parse go module info" {
    const allocator = std.testing.allocator;
    const info = try parseInfo(
        allocator,
        \\module example.com/demo
        \\
        \\go 1.24.0
    ,
        "/tmp/demo/go.mod",
        "/tmp/demo/cmd/app/main.go",
    );
    defer freeOwnedInfo(allocator, info);

    try std.testing.expect(info.module_name != null);
    try std.testing.expectEqualStrings("example.com/demo", info.module_name.?);
    try std.testing.expect(info.primary_selector != null);
    try std.testing.expectEqualStrings("./cmd/app", info.primary_selector.?);
    try std.testing.expect(info.primary_run != null);
    try std.testing.expectEqualStrings("go run './cmd/app'", info.primary_run.?);
}
