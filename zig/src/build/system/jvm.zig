const std = @import("std");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
const gradle_markers = &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" };

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0) {
            if (shared.pathHasFile(root, "pom.xml")) {
                return try buildResult(allocator, root, "maven");
            }
            if (shared.pathHasAnyMarker(root, gradle_markers)) {
                return try buildResult(allocator, root, "gradle");
            }
        }
    }

    if (try findJvmRootAlloc(allocator, path, 12)) |result| {
        return result;
    }

    return .{};
}

fn findJvmRootAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    max_up: usize,
) !?Result {
    var current = try allocator.dupe(u8, std.fs.path.dirname(start_path) orelse start_path);
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (shared.pathHasFile(current, "pom.xml")) {
            return try buildResult(allocator, current, "maven");
        }
        if (shared.pathHasAnyMarker(current, gradle_markers)) {
            return try buildResult(allocator, current, "gradle");
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8, system: []const u8) !Result {
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = if (std.mem.eql(u8, system, "maven"))
        try buildMavenCommandsAlloc(allocator)
    else
        try buildGradleCommandsAlloc(allocator, root);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = system, .commands = commands };
}

fn buildMavenCommandsAlloc(allocator: std.mem.Allocator) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const build_command = try allocator.dupe(u8, "mvn compile");
    const test_command = try allocator.dupe(u8, "mvn test");
    const package_command = try allocator.dupe(u8, "mvn package");

    try shared.appendOwnedCommand(&commands, allocator, "mvn-build", build_command);
    try shared.appendOwnedCommand(&commands, allocator, "mvn-test", test_command);
    try shared.appendOwnedCommand(&commands, allocator, "mvn-package", package_command);
    try shared.appendDupedCommand(&commands, allocator, "build", build_command);
    try shared.appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
}

fn buildGradleCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const wrapper_path = try std.fs.path.join(allocator, &.{ root, "gradlew" });
    defer allocator.free(wrapper_path);
    const prefix: []const u8 = if (shared.pathExists(wrapper_path)) "./gradlew" else "gradle";

    const build_command = try std.fmt.allocPrint(allocator, "{s} build", .{prefix});
    const test_command = try std.fmt.allocPrint(allocator, "{s} test", .{prefix});
    const clean_command = try std.fmt.allocPrint(allocator, "{s} clean", .{prefix});

    try shared.appendOwnedCommand(&commands, allocator, "gradle-build", build_command);
    try shared.appendOwnedCommand(&commands, allocator, "gradle-test", test_command);
    try shared.appendOwnedCommand(&commands, allocator, "gradle-clean", clean_command);
    try shared.appendDupedCommand(&commands, allocator, "build", build_command);
    try shared.appendDupedCommand(&commands, allocator, "test", test_command);
    try shared.appendDupedCommand(&commands, allocator, "clean", clean_command);

    return try commands.toOwnedSlice(allocator);
}
