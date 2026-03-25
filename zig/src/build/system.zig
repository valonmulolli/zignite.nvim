const std = @import("std");
const common = @import("common.zig");

pub const Query = enum {
    c_family,
    bazel_root,
    jvm_root,
};

pub const CommandEntry = struct {
    name: []const u8,
    command: []u8,
};

pub const Result = struct {
    root: ?[]u8 = null,
    system: ?[]const u8 = null,
    build_ready: ?bool = null,
    commands: []CommandEntry = &.{},
};

pub fn parseQuery(value: []const u8) !Query {
    if (std.ascii.eqlIgnoreCase(value, "c-family")) return .c_family;
    if (std.ascii.eqlIgnoreCase(value, "bazel-root")) return .bazel_root;
    if (std.ascii.eqlIgnoreCase(value, "jvm-root")) return .jvm_root;
    return error.InvalidSystemQuery;
}

pub fn freeOwnedResult(allocator: std.mem.Allocator, result: Result) void {
    if (result.root) |root| allocator.free(root);
    for (result.commands) |entry| {
        allocator.free(entry.command);
    }
    if (result.commands.len > 0) {
        allocator.free(result.commands);
    }
}

pub fn detect(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return switch (query) {
        .c_family => try detectCFamily(allocator, path, project_root),
        .bazel_root => try detectBazelRoot(allocator, path, project_root),
        .jvm_root => try detectJvmRoot(allocator, path, project_root),
    };
}

fn detectCFamily(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0) {
            if (rootHasAnyMarker(root, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" })) {
                return .{ .root = try allocator.dupe(u8, root), .system = "bazel" };
            }
            if (rootHasAnyMarker(root, &.{"meson.build"})) {
                return try buildMesonResult(allocator, root);
            }
            if (rootHasAnyMarker(root, &.{"CMakeLists.txt"})) {
                return try buildCmakeResult(allocator, root);
            }
            if (pathHasFile(root, "Makefile")) {
                return .{ .root = try allocator.dupe(u8, root), .system = "make" };
            }
        }
    }

    if (try findRootForFilesAlloc(allocator, path, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }, 12)) |root| {
        return .{ .root = root, .system = "bazel" };
    }
    if (try findRootForFilesAlloc(allocator, path, &.{"meson.build"}, 12)) |root| {
        defer allocator.free(root);
        return try buildMesonResult(allocator, root);
    }
    if (try findRootForFilesAlloc(allocator, path, &.{"CMakeLists.txt"}, 12)) |root| {
        defer allocator.free(root);
        return try buildCmakeResult(allocator, root);
    }
    if (try findRootForFilesAlloc(allocator, path, &.{"Makefile"}, 12)) |root| {
        return .{ .root = root, .system = "make" };
    }

    const root = try resolveBaseRoot(allocator, path, project_root);
    return .{ .root = root };
}

fn buildCmakeResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const build_ready = common.hasCmakeBuildTree(root);
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildCmakeCommandsAlloc(allocator, root, build_ready);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "cmake", .build_ready = build_ready, .commands = commands };
}

fn buildMesonResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const build_ready = common.hasMesonBuildTree(root);
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildMesonCommandsAlloc(allocator, root, build_ready);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "meson", .build_ready = build_ready, .commands = commands };
}

fn buildCmakeCommandsAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const config_command = try allocator.dupe(u8, "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1");
    const build_command = try common.cmakeBuildCommandAlloc(allocator, root, null);
    const clean_command = try allocator.dupe(u8, if (build_ready) "cmake --build build --target clean" else "cmake -E rm -rf build");
    const debug_command = try allocator.dupe(
        u8,
        "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
    );
    const release_command = try allocator.dupe(
        u8,
        "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build",
    );
    const test_command = try allocator.dupe(u8, "ctest --test-dir build");
    const install_command = try allocator.dupe(u8, "cmake --build build --target install");

    try appendOwnedCommand(&commands, allocator, "cmake-config", config_command);
    try appendOwnedCommand(&commands, allocator, "cmake-build", build_command);
    try appendOwnedCommand(&commands, allocator, "cmake-clean", clean_command);
    try appendOwnedCommand(&commands, allocator, "cmake-debug", debug_command);
    try appendOwnedCommand(&commands, allocator, "cmake-release", release_command);
    try appendOwnedCommand(&commands, allocator, "cmake-test", test_command);
    try appendOwnedCommand(&commands, allocator, "install", install_command);
    try appendDupedCommand(&commands, allocator, "config", config_command);
    try appendDupedCommand(&commands, allocator, "build", build_command);
    try appendDupedCommand(&commands, allocator, "clean", clean_command);
    try appendDupedCommand(&commands, allocator, "debug", debug_command);
    try appendDupedCommand(&commands, allocator, "release", release_command);
    try appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
}

fn buildMesonCommandsAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    build_ready: bool,
) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const setup_command = try allocator.dupe(u8, "meson setup build");
    const build_command = try common.mesonBuildCommandAlloc(allocator, root, null);
    const clean_command = try allocator.dupe(
        u8,
        if (build_ready) "meson compile -C build --clean" else "cmake -E rm -rf build",
    );
    const test_command = try allocator.dupe(u8, "meson test -C build");
    const install_command = try allocator.dupe(u8, "meson install -C build");

    try appendOwnedCommand(&commands, allocator, "meson-setup", setup_command);
    try appendOwnedCommand(&commands, allocator, "meson-build", build_command);
    try appendOwnedCommand(&commands, allocator, "meson-clean", clean_command);
    try appendOwnedCommand(&commands, allocator, "meson-test", test_command);
    try appendOwnedCommand(&commands, allocator, "install", install_command);
    try appendDupedCommand(&commands, allocator, "setup", setup_command);
    try appendDupedCommand(&commands, allocator, "build", build_command);
    try appendDupedCommand(&commands, allocator, "clean", clean_command);
    try appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
}

fn buildBazelCommandsAlloc(allocator: std.mem.Allocator) ![]CommandEntry {
    var commands: std.ArrayList(CommandEntry) = .empty;
    errdefer {
        for (commands.items) |entry| allocator.free(entry.command);
        commands.deinit(allocator);
    }

    const query_command = try allocator.dupe(u8, "bazel query $zignite_args");
    const clean_command = try allocator.dupe(u8, "bazel clean");
    const build_command = try allocator.dupe(u8, "bazel build //...");
    const test_command = try allocator.dupe(u8, "bazel test //...");

    try appendOwnedCommand(&commands, allocator, "bazel-query", query_command);
    try appendOwnedCommand(&commands, allocator, "bazel-clean", clean_command);
    try appendOwnedCommand(&commands, allocator, "bazel-build-all", build_command);
    try appendOwnedCommand(&commands, allocator, "bazel-test-all", test_command);
    try appendDupedCommand(&commands, allocator, "build", build_command);
    try appendDupedCommand(&commands, allocator, "test", test_command);

    return try commands.toOwnedSlice(allocator);
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

    try appendOwnedCommand(&commands, allocator, "mvn-build", build_command);
    try appendOwnedCommand(&commands, allocator, "mvn-test", test_command);
    try appendOwnedCommand(&commands, allocator, "mvn-package", package_command);
    try appendDupedCommand(&commands, allocator, "build", build_command);
    try appendDupedCommand(&commands, allocator, "test", test_command);

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
    const prefix: []const u8 = if (pathExists(wrapper_path)) "./gradlew" else "gradle";

    const build_command = try std.fmt.allocPrint(allocator, "{s} build", .{prefix});
    const test_command = try std.fmt.allocPrint(allocator, "{s} test", .{prefix});
    const clean_command = try std.fmt.allocPrint(allocator, "{s} clean", .{prefix});

    try appendOwnedCommand(&commands, allocator, "gradle-build", build_command);
    try appendOwnedCommand(&commands, allocator, "gradle-test", test_command);
    try appendOwnedCommand(&commands, allocator, "gradle-clean", clean_command);
    try appendDupedCommand(&commands, allocator, "build", build_command);
    try appendDupedCommand(&commands, allocator, "test", test_command);
    try appendDupedCommand(&commands, allocator, "clean", clean_command);

    return try commands.toOwnedSlice(allocator);
}

fn appendOwnedCommand(
    commands: *std.ArrayList(CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []u8,
) !void {
    try commands.append(allocator, .{ .name = name, .command = command });
}

fn appendDupedCommand(
    commands: *std.ArrayList(CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    source_command: []const u8,
) !void {
    try commands.append(allocator, .{
        .name = name,
        .command = try allocator.dupe(u8, source_command),
    });
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn detectBazelRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0 and rootHasAnyMarker(root, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" })) {
            return try buildBazelResult(allocator, root);
        }
    }

    if (try findRootForFilesAlloc(allocator, path, &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }, 12)) |root| {
        defer allocator.free(root);
        return try buildBazelResult(allocator, root);
    }

    return .{};
}

fn detectJvmRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    if (project_root) |root| {
        if (root.len > 0) {
            if (pathHasFile(root, "pom.xml")) {
                return try buildJvmResult(allocator, root, "maven");
            }
            if (pathHasAnyMarker(root, &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" })) {
                return try buildJvmResult(allocator, root, "gradle");
            }
        }
    }

    if (try findJvmRootAlloc(allocator, path, 12)) |result| {
        return result;
    }

    return .{};
}

fn resolveBaseRoot(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) ![]u8 {
    if (project_root) |root| {
        if (root.len > 0) return allocator.dupe(u8, root);
    }
    return allocator.dupe(u8, std.fs.path.dirname(path) orelse path);
}

fn findRootForFilesAlloc(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    markers: []const []const u8,
    max_up: usize,
) !?[]u8 {
    var current = try allocator.dupe(u8, std.fs.path.dirname(start_path) orelse start_path);
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (pathHasAnyMarker(current, markers)) {
            return try allocator.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
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
        if (pathHasFile(current, "pom.xml")) {
            return try buildJvmResult(allocator, current, "maven");
        }
        if (pathHasAnyMarker(current, &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" })) {
            return try buildJvmResult(allocator, current, "gradle");
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

fn buildBazelResult(allocator: std.mem.Allocator, root: []const u8) !Result {
    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const commands = try buildBazelCommandsAlloc(allocator);
    errdefer {
        for (commands) |entry| allocator.free(entry.command);
        allocator.free(commands);
    }
    return .{ .root = owned_root, .system = "bazel", .commands = commands };
}

fn buildJvmResult(allocator: std.mem.Allocator, root: []const u8, system: []const u8) !Result {
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

fn rootHasAnyMarker(root: []const u8, markers: []const []const u8) bool {
    return pathHasAnyMarker(root, markers);
}

fn pathHasAnyMarker(root: []const u8, markers: []const []const u8) bool {
    for (markers) |marker| {
        if (pathHasFile(root, marker)) return true;
    }
    return false;
}

fn pathHasFile(root: []const u8, name: []const u8) bool {
    const full_path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(full_path);

    if (std.fs.path.isAbsolute(full_path)) {
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}

test "detect c family system and build readiness" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build");
    try tmp.dir.writeFile(.{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });
    try tmp.dir.writeFile(.{ .sub_path = "build/CMakeCache.txt", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("cmake", result.system.?);
    try std.testing.expect(result.build_ready.?);
    try std.testing.expect(result.commands.len > 0);
    try std.testing.expectEqualStrings("cmake --build build", findCommand(result.commands, "cmake-build").?);
    try std.testing.expectEqualStrings("cmake --build build", findCommand(result.commands, "build").?);
}

test "detect c family by walking parent markers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "nested", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("cmake", result.system.?);
}

test "detect c family meson emits setup-prefixed build commands when build tree is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "meson.build", .data = "project('demo')\n" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("meson", result.system.?);
    try std.testing.expectEqual(false, result.build_ready.?);
    try std.testing.expectEqualStrings(
        "meson setup build && meson compile -C build",
        findCommand(result.commands, "meson-build").?,
    );
    try std.testing.expectEqualStrings(
        "meson setup build && meson compile -C build",
        findCommand(result.commands, "build").?,
    );
}

fn findCommand(commands: []const CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

test "detect bazel root emits baseline commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app");
    try tmp.dir.writeFile(.{ .sub_path = "WORKSPACE", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.cc" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .bazel_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("bazel", result.system.?);
    try std.testing.expectEqualStrings("bazel build //...", findCommand(result.commands, "build").?);
}

test "detect jvm root emits baseline gradle commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/main/kotlin");
    try tmp.dir.writeFile(.{ .sub_path = "build.gradle.kts", .data = "plugins { kotlin(\"jvm\") }\n" });
    try tmp.dir.writeFile(.{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main", "kotlin", "App.kt" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .jvm_root, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("gradle", result.system.?);
    try std.testing.expectEqualStrings("./gradlew build", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("./gradlew clean", findCommand(result.commands, "clean").?);
}

test "detect bazel root by walking parents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app");
    try tmp.dir.writeFile(.{ .sub_path = "MODULE.bazel", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.cc" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .bazel_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("bazel", result.system.?);
}

test "detect jvm root and kind" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "gradlew", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "build.gradle.kts", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "Main.kt" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .jvm_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("gradle", result.system.?);
}
