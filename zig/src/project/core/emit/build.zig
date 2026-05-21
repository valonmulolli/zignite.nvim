const std = @import("std");
const bazel_emit = @import("build/bazel.zig");
const cmake_emit = @import("build/cmake.zig");
const meson_emit = @import("build/meson.zig");
const fixtures = @import("../../../test_support/fixtures.zig");
const types = @import("../types.zig");

const Options = types.Options;

pub fn writeBuildOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeBuildOutputWithIO(threaded.io(), stdout, allocator, options, contents);
}

pub fn writeBuildOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !bool {
    switch (options.kind) {
        .cmake => {
            try cmake_emit.writeCmakeOutputWithIO(io, stdout, allocator, options, contents);
            return true;
        },
        .meson => {
            try meson_emit.writeMesonOutputWithIO(io, stdout, allocator, options, contents);
            return true;
        },
        .bazel => {
            try bazel_emit.writeBazelProjectOutput(stdout, allocator, options, contents);
            return true;
        },
        .bazel_workspace => {
            try bazel_emit.writeBazelWorkspaceOutputWithIO(io, stdout, allocator, options);
            return true;
        },
        else => return false,
    }
}

test "writeBuildOutput emits cmake primary target and discovered run path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build/bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/bin/demo-app", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const cmake_path = try std.fs.path.join(allocator, &.{ root, "CMakeLists.txt" });
    defer allocator.free(cmake_path);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = match_path,
    },
        \\project(demo-app)
        \\add_executable(${PROJECT_NAME} src/main.cpp)
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "TARGET\tdemo-app\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcmake-build-demo-app\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcmake-run-demo-app\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "RUN_PATH\tdemo-app\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_TARGET\tdemo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN_PATH\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tclean\tpython -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tctest --test-dir build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tclean\tpython -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\ttest\tctest --test-dir build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tinstall\tcmake --build build --target install\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
}

test "writeBuildOutput emits meson preferred command aliases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "meson.build", .data =
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/build.ninja", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/demo-app", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const meson_path = try std.fs.path.join(allocator, &.{ root, "meson.build" });
    defer allocator.free(meson_path);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    },
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tsetup\tmeson setup build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tsetup\tmeson setup build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tclean\tmeson compile -C build --clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tmeson test -C build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmeson compile -C build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tclean\tmeson compile -C build --clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\ttest\tmeson test -C build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tinstall\tmeson install -C build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tbuild\tmeson compile -C build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
}

test "writeBuildOutput emits meson portable clean fallback without build tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "meson.build", .data =
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    });

    const meson_path = try tmp.dir.realPathFileAlloc(std.testing.io, "meson.build", allocator);
    defer allocator.free(meson_path);
    const match_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(meson_path) orelse "", "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    },
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tclean\tpython -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tclean\tpython -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' -- build\n") != null);
}

test "writeBuildOutput emits bazel commands and primary targets" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .bazel,
        .path = "/tmp/bazelzig/app/BUILD.bazel",
        .match_path = "/tmp/bazelzig/app/main.cc",
        .package_path = "app",
    },
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
        \\
        \\cc_test(
        \\    name = "main_test",
        \\    srcs = ["main_test.cc"],
        \\)
    ));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-run-app-main\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-test-app-main_test\tbazel test //app:main_test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-query\tbazel query $zignite_args\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-clean\tbazel clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-all\tbazel build //...\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-test-all\tbazel test //...\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-run\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BUILD\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\tbazel run //app:main\n") != null);
}

test "writeBuildOutput emits bazel workspace commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
        \\
        \\cc_test(
        \\    name = "main_test",
        \\    srcs = ["main_test.cc"],
        \\)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(workspace_root);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.cc", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .bazel_workspace,
        .path = workspace_root,
        .match_path = match_path,
    }, ""));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-run-app-main\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-test-app-main_test\tbazel test //app:main_test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-query\tbazel query $zignite_args\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-clean\tbazel clean\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-all\tbazel build //...\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-test-all\tbazel test //...\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-run\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BUILD\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\tbazel run //app:main\n") != null);
}

test "writeBuildOutput emits cmake commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeCmakeProject(tmp.dir);
    try tmp.dir.createDirPath(std.testing.io, "build/bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/bin/demo-app", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const cmake_path = try tmp.dir.realPathFileAlloc(std.testing.io, "CMakeLists.txt", allocator);
    defer allocator.free(cmake_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.cpp", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "CMakeLists.txt", allocator, .limited(4096));
    defer allocator.free(contents);

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcmake-build-demo-app\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
}

test "writeBuildOutput prefers CMake File API targets and artifacts when available" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeCmakeFileApiProject(tmp.dir);

    const cmake_path = try tmp.dir.realPathFileAlloc(std.testing.io, "CMakeLists.txt", allocator);
    defer allocator.free(cmake_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.cpp", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "CMakeLists.txt", allocator, .limited(4096));
    defer allocator.free(contents);

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "TARGET\thelper\t0\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "TARGET\tdemo-app\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_TARGET\tdemo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN_PATH\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcmake-run-demo-app\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
}

test "writeBuildOutput emits meson commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeMesonProject(tmp.dir);
    try tmp.dir.createDirPath(std.testing.io, "build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/build.ninja", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/demo-app", .data = "" });

    const meson_path = try tmp.dir.realPathFileAlloc(std.testing.io, "meson.build", allocator);
    defer allocator.free(meson_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.cpp", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "meson.build", allocator, .limited(4096));
    defer allocator.free(contents);

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmeson-build-demo-app\tmeson compile -C build demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmeson compile -C build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
}

test "writeBuildOutput prefers Meson introspection targets and artifacts when available" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeMesonIntroProject(tmp.dir);

    const meson_path = try tmp.dir.realPathFileAlloc(std.testing.io, "meson.build", allocator);
    defer allocator.free(meson_path);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.cpp", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const contents = try tmp.dir.readFileAlloc(std.testing.io, "meson.build", allocator, .limited(4096));
    defer allocator.free(contents);

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    }, contents));

    try std.testing.expect(std.mem.find(u8, out.written(), "TARGET\thelper\t0\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "TARGET\tdemo-app\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_TARGET\tdemo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN_PATH\t./build/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tmeson-run-demo-app\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
}

test "writeBuildOutput emits bazel workspace commands from fixture project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try fixtures.writeBazelWorkspace(tmp.dir);

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(workspace_root);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.cc", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .bazel_workspace,
        .path = workspace_root,
        .match_path = match_path,
    }, ""));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-test-app-main_test\tbazel test //app:main_test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_RUN\tbazel run //app:main\n") != null);
}

test "writeBuildOutput keeps nearest bazel package as primary and preserves same target names" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["app/main.cc"],
        \\)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(workspace_root);
    const match_path = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.cc", allocator);
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeBuildOutput(&out.writer, allocator, .{
        .kind = .bazel_workspace,
        .path = workspace_root,
        .match_path = match_path,
    }, ""));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-main\tbazel build //:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BUILD\tbazel build //app:main\n") != null);
}
