const std = @import("std");
const bazel = @import("system/bazel.zig");
const c_family = @import("system/c_family.zig");
const jvm = @import("system/jvm.zig");
const node = @import("system/node.zig");
const python = @import("system/python.zig");
const types = @import("system/types.zig");

pub const Query = types.Query;
pub const CommandEntry = types.CommandEntry;
pub const Result = types.Result;
pub const parseQuery = types.parseQuery;
pub const freeOwnedResult = types.freeOwnedResult;

pub fn detect(
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return switch (query) {
        .c_family => try c_family.detect(allocator, path, project_root),
        .bazel_root => try bazel.detect(allocator, path, project_root),
        .jvm_root => try jvm.detect(allocator, path, project_root),
        .node_root => try node.detect(allocator, path, project_root),
        .python_root => try python.detect(allocator, path, project_root),
    };
}

fn findCommand(commands: []const CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
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

test "detect python root emits uv commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app");
    try tmp.dir.writeFile(.{ .sub_path = "pyproject.toml", .data =
        \\[project]
        \\name = "demo"
        \\
        \\[tool.uv]
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.py" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .python_root, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("uv run -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("uv run pytest", findCommand(result.commands, "test").?);
    try std.testing.expectEqualStrings("uv sync", findCommand(result.commands, "install").?);
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

test "detect c family make emits baseline aliases from Makefile targets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "Makefile", .data = "run:\n\t@echo run\nclean:\n\t@echo clean\n" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("make", result.system.?);
    try std.testing.expectEqualStrings("make", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("make run", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("make clean", findCommand(result.commands, "clean").?);
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

test "detect node root emits package-manager baseline commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "pnpm-lock.yaml", .data = "lockfileVersion: '9.0'" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .node_root, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("node", result.system.?);
    try std.testing.expectEqualStrings("pnpm run build", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("pnpm install", findCommand(result.commands, "install").?);
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
