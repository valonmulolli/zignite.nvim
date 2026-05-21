const std = @import("std");
const shared = @import("shared.zig");
const types = @import("types.zig");

const Result = types.Result;
const CommandEntry = types.CommandEntry;
pub const maven_markers = &.{"pom.xml"};
pub const gradle_markers = &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" };
pub const markers = &.{ "pom.xml", "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" };

pub fn detect(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return detectWithIO(threaded.io(), allocator, path, project_root);
}

pub fn detectWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0) {
            if (try findJvmRootAllocWithIO(io, allocator, path, root, 12)) |result| {
                return result;
            }
            return .{};
        }
    }

    if (try findJvmRootAllocWithIO(io, allocator, path, null, 12)) |result| {
        return result;
    }

    return .{};
}

fn findJvmRootAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    boundary: ?[]const u8,
    max_up: usize,
) !?Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return findJvmRootAllocWithIO(threaded.io(), allocator, start_path, boundary, max_up);
}

fn findJvmRootAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    start_path: []const u8,
    boundary: ?[]const u8,
    max_up: usize,
) !?Result {
    var best_root: ?[]u8 = null;
    errdefer if (best_root) |root| allocator.free(root);
    var best_system: ?[]const u8 = null;

    const searches = [_]struct {
        system: []const u8,
        markers: []const []const u8,
    }{
        .{ .system = "maven", .markers = maven_markers },
        .{ .system = "gradle", .markers = gradle_markers },
    };

    inline for (searches) |search| {
        if (try shared.findRootForFilesWithinAllocWithIO(io, allocator, start_path, search.markers, boundary, max_up)) |root| {
            if (shared.replaceDeeperOwnedRoot(allocator, &best_root, root)) {
                best_system = search.system;
            }
        }
    }

    if (best_root) |root| {
        defer allocator.free(root);
        return try buildResultWithIO(io, allocator, root, best_system.?);
    }

    return null;
}

test "detect does not escape explicit project root boundary" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/apps/app/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/pom.xml", .data = "<project/>" });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo/apps/app", allocator);
    defer allocator.free(app_root);
    const filepath = try std.fs.path.join(allocator, &.{ app_root, "src", "Main.java" });
    defer allocator.free(filepath);

    const result = try detect(allocator, filepath, app_root);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expect(result.root == null);
    try std.testing.expect(result.system == null);
    try std.testing.expectEqual(@as(usize, 0), result.commands.len);
}

test "detect prefers nested JVM module inside explicit project root" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/service/src/main/java");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/pom.xml", .data = "<project/>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/service/pom.xml", .data = "<project/>" });

    const repo_root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", allocator);
    defer allocator.free(repo_root);
    const service_root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo/service", allocator);
    defer allocator.free(service_root);
    const filepath = try std.fs.path.join(allocator, &.{ service_root, "src", "main", "java", "App.java" });
    defer allocator.free(filepath);

    const result = try detect(allocator, filepath, repo_root);
    defer types.freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(service_root, result.root.?);
    try std.testing.expectEqualStrings("maven", result.system.?);
}

fn buildResult(allocator: std.mem.Allocator, root: []const u8, system: []const u8) !Result {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildResultWithIO(threaded.io(), allocator, root, system);
}

fn buildResultWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8, system: []const u8) !Result {
    const commands = if (std.mem.eql(u8, system, "maven"))
        try buildMavenCommandsAlloc(allocator)
    else
        try buildGradleCommandsAllocWithIO(io, allocator, root);
    return try shared.makeResult(allocator, root, system, null, commands);
}

fn buildMavenCommandsAlloc(allocator: std.mem.Allocator) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    try shared.appendOwnedCommandWithAliases(&commands, allocator, "mvn-build", try allocator.dupe(u8, "mvn compile"), &.{"build"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "mvn-test", try allocator.dupe(u8, "mvn test"), &.{"test"});
    try shared.appendDupedCommand(&commands, allocator, "mvn-package", "mvn package");

    return try commands.toOwnedSlice(allocator);
}

fn buildGradleCommandsAlloc(allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildGradleCommandsAllocWithIO(threaded.io(), allocator, root);
}

fn buildGradleCommandsAllocWithIO(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer shared.deinitCommandList(allocator, &commands);

    const wrapper_path = try std.fs.path.join(allocator, &.{ root, "gradlew" });
    defer allocator.free(wrapper_path);
    const prefix: []const u8 = if (shared.pathExistsWithIO(io, wrapper_path)) "./gradlew" else "gradle";

    try shared.appendOwnedCommandWithAliases(&commands, allocator, "gradle-build", try std.fmt.allocPrint(allocator, "{s} build", .{prefix}), &.{"build"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "gradle-test", try std.fmt.allocPrint(allocator, "{s} test", .{prefix}), &.{"test"});
    try shared.appendOwnedCommandWithAliases(&commands, allocator, "gradle-clean", try std.fmt.allocPrint(allocator, "{s} clean", .{prefix}), &.{"clean"});

    return try commands.toOwnedSlice(allocator);
}
