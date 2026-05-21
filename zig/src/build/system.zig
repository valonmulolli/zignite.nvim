const std = @import("std");
const cache = @import("system/cache.zig");
const fixtures = @import("../test_support/fixtures.zig");
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
    return try cache.detect(allocator, query, path, project_root);
}

pub fn detectWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    query: Query,
    path: []const u8,
    project_root: ?[]const u8,
) !Result {
    return try cache.detectWithIO(io, allocator, query, path, project_root);
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

    try tmp.dir.createDirPath(std.testing.io, "build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/CMakeCache.txt", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pyproject.toml", .data =
        \\[project]
        \\name = "demo"
        \\
        \\[tool.uv]
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

test "detect python root emits uv commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writePythonProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .python_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("uv run -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("uv run pytest", findCommand(result.commands, "test").?);
    try std.testing.expectEqualStrings("uv sync", findCommand(result.commands, "install").?);
}

test "detect python root emits conda commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writePythonCondaProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .python_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("conda run -n demo-conda python -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("conda run -n demo-conda pytest", findCommand(result.commands, "test").?);
    try std.testing.expectEqualStrings("conda env update -f environment.yml --prune", findCommand(result.commands, "install").?);
}

test "detect python root emits conda commands from environment.yaml fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writePythonCondaYamlProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .python_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("conda run -n demo-conda-yaml python -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("conda run -n demo-conda-yaml pytest", findCommand(result.commands, "test").?);
    try std.testing.expectEqualStrings("conda env update -f environment.yaml --prune", findCommand(result.commands, "install").?);
}

test "detect python root emits unnamed conda commands without environment name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "environment.yml", .data =
        \\dependencies:
        \\  - python=3.12
        \\  - pytest
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.py", .data =
        \\def main():
        \\    print("hello")
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .python_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("conda run python -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("conda run pytest", findCommand(result.commands, "test").?);
    try std.testing.expectEqualStrings("conda env update -f environment.yml --prune", findCommand(result.commands, "install").?);
}

test "detect python root emits requirements commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writePythonRequirementsProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.py", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .python_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("python", result.system.?);
    try std.testing.expectEqualStrings("python -m main", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("pytest", findCommand(result.commands, "test").?);
    try std.testing.expectEqualStrings("pip install -r requirements.txt", findCommand(result.commands, "install").?);
}

test "detect c family by walking parent markers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "run:\n\t@echo run\nclean:\n\t@echo clean\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

test "detect c family make supports GNUmakefile markers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "GNUmakefile", .data = "run:\n\t@echo run\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("make", result.system.?);
    try std.testing.expectEqualStrings("make", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("make run", findCommand(result.commands, "run").?);
}

test "detect c family make follows included make targets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data =
        \\include tasks.mk
        \\all:
        \\\t@echo all
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tasks.mk", .data =
        \\.PHONY: serve verify
        \\serve:
        \\\t@echo serve
        \\verify:
        \\\t@echo verify
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("make", result.system.?);
    try std.testing.expectEqualStrings("make", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("make serve", findCommand(result.commands, "run").?);
    try std.testing.expectEqualStrings("make verify", findCommand(result.commands, "test").?);
}

test "detect c family meson emits setup-prefixed build commands when build tree is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "meson.build", .data = "project('demo')\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    try std.testing.expectEqualStrings(
        "python -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- build",
        findCommand(result.commands, "clean").?,
    );
}

test "detect c family cmake uses discovered custom build directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, "build-debug");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(demo)\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build-debug/CMakeCache.txt", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("cmake", result.system.?);
    try std.testing.expect(result.build_ready.?);
    try std.testing.expectEqualStrings("cmake --build build-debug", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("ctest --test-dir build-debug", findCommand(result.commands, "test").?);
}

test "detect c family meson uses discovered custom build directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, "build-debug");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "meson.build", .data = "project('demo')\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build-debug/build.ninja", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("meson", result.system.?);
    try std.testing.expect(result.build_ready.?);
    try std.testing.expectEqualStrings("meson compile -C build-debug", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("meson test -C build-debug", findCommand(result.commands, "test").?);
}

test "detect bazel root emits baseline commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "WORKSPACE", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.cc" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .bazel_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("bazel", result.system.?);
    try std.testing.expectEqualStrings("bazel build //...", findCommand(result.commands, "build").?);
}

test "detect c family in bazel workspace emits bazel baseline commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.cc" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("bazel", result.system.?);
    try std.testing.expectEqualStrings("bazel build //...", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("bazel test //...", findCommand(result.commands, "test").?);
}

test "detect c family prefers nested cmake project over outer bazel workspace" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "third_party/demo/src");
    try tmp.dir.createDirPath(std.testing.io, "third_party/demo/build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "third_party/demo/src/main.cpp", .data = "int main() { return 0; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "third_party/demo/CMakeLists.txt", .data =
        \\project(demo)
        \\add_executable(demo src/main.cpp)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "third_party/demo/build/CMakeCache.txt", .data = "" });

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(workspace_root);
    const nested_root = try tmp.dir.realPathFileAlloc(std.testing.io, "third_party/demo", allocator);
    defer allocator.free(nested_root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "third_party/demo/src/main.cpp", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .c_family, filepath, workspace_root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(nested_root, result.root.?);
    try std.testing.expectEqualStrings("cmake", result.system.?);
    try std.testing.expectEqualStrings("cmake --build build", findCommand(result.commands, "build").?);
}

test "detect jvm root emits baseline gradle commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/main/kotlin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.gradle.kts", .data = "plugins { kotlin(\"jvm\") }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main", "kotlin", "App.kt" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .jvm_root, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("gradle", result.system.?);
    try std.testing.expectEqualStrings("./gradlew build", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("./gradlew clean", findCommand(result.commands, "clean").?);
}

test "detect node root emits install only when no scripts exist" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package.json", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pnpm-lock.yaml", .data = "lockfileVersion: '9.0'" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .node_root, filepath, root);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings("node", result.system.?);
    try std.testing.expectEqualStrings("pnpm install", findCommand(result.commands, "install").?);
    try std.testing.expect(findCommand(result.commands, "build") == null);
    try std.testing.expect(findCommand(result.commands, "dev") == null);
    try std.testing.expect(findCommand(result.commands, "start") == null);
    try std.testing.expect(findCommand(result.commands, "test") == null);
}

test "detect node root emits bun baseline commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeBunProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.ts", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .node_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("node", result.system.?);
    try std.testing.expectEqualStrings("bun run build", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("bun install", findCommand(result.commands, "install").?);
}

test "detect node root emits yarn baseline commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeYarnProject(tmp.dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "package.json", allocator);
    defer allocator.free(filepath);

    const result = try detect(allocator, .node_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("node", result.system.?);
    try std.testing.expectEqualStrings("yarn build", findCommand(result.commands, "build").?);
    try std.testing.expectEqualStrings("yarn install", findCommand(result.commands, "install").?);
    try std.testing.expectEqualStrings("yarn dev", findCommand(result.commands, "dev").?);
}

test "detect bazel root by walking parents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gradlew", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.gradle.kts", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "Main.kt" });
    defer allocator.free(filepath);

    const result = try detect(allocator, .jvm_root, filepath, null);
    defer freeOwnedResult(allocator, result);

    try std.testing.expect(result.root != null);
    try std.testing.expectEqualStrings(root, result.root.?);
    try std.testing.expectEqualStrings("gradle", result.system.?);
}
