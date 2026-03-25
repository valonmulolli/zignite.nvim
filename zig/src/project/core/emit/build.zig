const std = @import("std");
const bazel = @import("../../bazel/api.zig");
const build_common = @import("../../../build/common.zig");
const cmake = @import("../../cmake/api.zig");
const meson = @import("../../meson/api.zig");
const types = @import("../types.zig");

const Options = types.Options;

pub fn writeBuildOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !bool {
    switch (options.kind) {
        .cmake => {
            try writeCmakeOutput(stdout, allocator, options, contents);
            return true;
        },
        .meson => {
            try writeMesonOutput(stdout, allocator, options, contents);
            return true;
        },
        .bazel => {
            try writeBazelProjectOutput(stdout, allocator, options, contents);
            return true;
        },
        .bazel_workspace => {
            try writeBazelWorkspaceOutput(stdout, allocator, options);
            return true;
        },
        else => return false,
    }
}

fn writeCmakeOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    const items = try cmake.parseTargets(allocator, contents, options.path, options.match_path);
    defer cmake.freeOwnedTargets(allocator, items);
    var primary_target: ?[]const u8 = null;
    for (items) |item| {
        if (item.matched and primary_target == null) primary_target = item.name;
    }
    if (primary_target == null and items.len > 0) primary_target = items[0].name;

    const root = std.fs.path.dirname(options.path) orelse "";
    const cmake_config_command = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1";
    const cmake_clean_command = if (build_common.hasCmakeBuildTree(root))
        "cmake --build build --target clean"
    else
        "cmake -E rm -rf build";
    const cmake_debug_command =
        "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build";
    const cmake_release_command =
        "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build";
    const cmake_test_command = "ctest --test-dir build";
    const cmake_install_command = "cmake --build build --target install";
    try stdout.print("COMMAND\tcmake-config\t{s}\n", .{cmake_config_command});
    try stdout.print("COMMAND\tcmake-clean\t{s}\n", .{cmake_clean_command});
    try stdout.print("COMMAND\tcmake-debug\t{s}\n", .{cmake_debug_command});
    try stdout.print("COMMAND\tcmake-release\t{s}\n", .{cmake_release_command});
    try stdout.print("COMMAND\tcmake-test\t{s}\n", .{cmake_test_command});
    try stdout.print("COMMAND\tinstall\t{s}\n", .{cmake_install_command});
    try stdout.print("COMMAND\tconfig\t{s}\n", .{cmake_config_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{cmake_clean_command});
    try stdout.print("COMMAND\tdebug\t{s}\n", .{cmake_debug_command});
    try stdout.print("COMMAND\trelease\t{s}\n", .{cmake_release_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{cmake_test_command});
    try stdout.print("PREFERRED\tconfig\t{s}\n", .{cmake_config_command});
    try stdout.print("PREFERRED\tclean\t{s}\n", .{cmake_clean_command});
    try stdout.print("PREFERRED\tdebug\t{s}\n", .{cmake_debug_command});
    try stdout.print("PREFERRED\trelease\t{s}\n", .{cmake_release_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{cmake_test_command});
    try stdout.print("PREFERRED\tinstall\t{s}\n", .{cmake_install_command});
    var primary_run_path: ?[]u8 = null;
    defer if (primary_run_path) |value| allocator.free(value);

    for (items) |item| {
        try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const run_path = try build_common.discoverBuildRunPathAlloc(allocator, root, item.name);
        defer if (run_path) |value| allocator.free(value);
        const build_command = try build_common.cmakeBuildCommandAlloc(allocator, root, item.name);
        defer allocator.free(build_command);
        try stdout.print("COMMAND\tcmake-build-{s}\t{s}\n", .{ item.name, build_command });

        const run_command = try build_common.cmakeRunCommandAlloc(allocator, root, item.name, run_path);
        defer allocator.free(run_command);
        try stdout.print("COMMAND\tcmake-run-{s}\t{s}\n", .{ item.name, run_command });

        if (run_path) |value| {
            try stdout.print("RUN_PATH\t{s}\t{s}\n", .{ item.name, value });
            if (primary_target != null and std.mem.eql(u8, item.name, primary_target.?) and primary_run_path == null) {
                primary_run_path = try allocator.dupe(u8, value);
            }
        }
    }
    if (primary_target) |name| {
        const preferred_build = try build_common.cmakeBuildCommandAlloc(allocator, root, null);
        defer allocator.free(preferred_build);
        try stdout.print("COMMAND\tcmake-build\t{s}\n", .{preferred_build});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{preferred_build});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{preferred_build});

        try stdout.print("PRIMARY_TARGET\t{s}\n", .{name});
        if (primary_run_path) |value| {
            try stdout.print("PRIMARY_RUN_PATH\t{s}\n", .{value});
        }
        const preferred_run = try build_common.cmakeRunCommandAlloc(allocator, root, name, primary_run_path);
        defer allocator.free(preferred_run);
        try stdout.print("COMMAND\tcmake-run\t{s}\n", .{preferred_run});
        try stdout.print("COMMAND\trun\t{s}\n", .{preferred_run});
        try stdout.print("PREFERRED\trun\t{s}\n", .{preferred_run});
    }
}

fn writeMesonOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    const items = try meson.parseTargets(allocator, contents, options.path, options.match_path);
    defer meson.freeOwnedTargets(allocator, items);
    var primary_target: ?[]const u8 = null;
    for (items) |item| {
        if (item.matched and primary_target == null) primary_target = item.name;
    }
    if (primary_target == null and items.len > 0) primary_target = items[0].name;

    const root = std.fs.path.dirname(options.path) orelse "";
    const meson_setup_command = "meson setup build";
    const meson_clean_command = if (build_common.hasMesonBuildTree(root))
        "meson compile -C build --clean"
    else
        "cmake -E rm -rf build";
    const meson_test_command = "meson test -C build";
    const meson_install_command = "meson install -C build";
    try stdout.print("COMMAND\tmeson-setup\t{s}\n", .{meson_setup_command});
    try stdout.print("COMMAND\tmeson-clean\t{s}\n", .{meson_clean_command});
    try stdout.print("COMMAND\tmeson-test\t{s}\n", .{meson_test_command});
    try stdout.print("COMMAND\tinstall\t{s}\n", .{meson_install_command});
    try stdout.print("COMMAND\tsetup\t{s}\n", .{meson_setup_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{meson_clean_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{meson_test_command});
    try stdout.print("PREFERRED\tsetup\t{s}\n", .{meson_setup_command});
    try stdout.print("PREFERRED\tclean\t{s}\n", .{meson_clean_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{meson_test_command});
    try stdout.print("PREFERRED\tinstall\t{s}\n", .{meson_install_command});
    var primary_run_path: ?[]u8 = null;
    defer if (primary_run_path) |value| allocator.free(value);

    for (items) |item| {
        try stdout.print("TARGET\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const run_path = try build_common.discoverBuildRunPathAlloc(allocator, root, item.name);
        defer if (run_path) |value| allocator.free(value);
        const build_command = try build_common.mesonBuildCommandAlloc(allocator, root, item.name);
        defer allocator.free(build_command);
        try stdout.print("COMMAND\tmeson-build-{s}\t{s}\n", .{ item.name, build_command });

        const run_command = try build_common.mesonRunCommandAlloc(allocator, root, item.name, run_path);
        defer allocator.free(run_command);
        try stdout.print("COMMAND\tmeson-run-{s}\t{s}\n", .{ item.name, run_command });

        if (run_path) |value| {
            try stdout.print("RUN_PATH\t{s}\t{s}\n", .{ item.name, value });
            if (primary_target != null and std.mem.eql(u8, item.name, primary_target.?) and primary_run_path == null) {
                primary_run_path = try allocator.dupe(u8, value);
            }
        }
    }
    if (primary_target) |name| {
        const preferred_build = try build_common.mesonBuildCommandAlloc(allocator, root, null);
        defer allocator.free(preferred_build);
        try stdout.print("COMMAND\tmeson-build\t{s}\n", .{preferred_build});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{preferred_build});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{preferred_build});

        try stdout.print("PRIMARY_TARGET\t{s}\n", .{name});
        if (primary_run_path) |value| {
            try stdout.print("PRIMARY_RUN_PATH\t{s}\n", .{value});
        }
        const preferred_run = try build_common.mesonRunCommandAlloc(allocator, root, name, primary_run_path);
        defer allocator.free(preferred_run);
        try stdout.print("COMMAND\tmeson-run\t{s}\n", .{preferred_run});
        try stdout.print("COMMAND\trun\t{s}\n", .{preferred_run});
        try stdout.print("PREFERRED\trun\t{s}\n", .{preferred_run});
    }
}

fn writeBazelProjectOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    const items = try bazel.parseTargets(allocator, contents);
    defer bazel.freeOwnedTargets(allocator, items);
    const info = try bazel.buildCommandInfo(
        allocator,
        items,
        options.path,
        options.package_path,
        options.match_path,
    );
    defer bazel.freeOwnedCommandInfo(allocator, info);

    for (items) |item| {
        try stdout.print("TARGET\t{s}\t{s}\t{d}\t{d}", .{
            item.rule_name,
            item.name,
            if (item.supports_run) @as(u8, 1) else @as(u8, 0),
            if (item.supports_test) @as(u8, 1) else @as(u8, 0),
        });
        for (item.source_entries) |entry| {
            try stdout.print("\t{s}", .{entry});
        }
        try stdout.writeByte('\n');
    }

    try writeBazelCommandInfo(stdout, info);
}

fn writeBazelWorkspaceOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    const info = try bazel.buildWorkspaceCommandInfo(allocator, options.path, options.match_path);
    defer bazel.freeOwnedCommandInfo(allocator, info);
    try writeBazelCommandInfo(stdout, info);
}

fn writeBazelCommandInfo(stdout: anytype, info: bazel.CommandInfo) !void {
    for (info.commands) |entry| {
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
    try stdout.print("COMMAND\tbazel-query\tbazel query $zignite_args\n", .{});
    try stdout.print("COMMAND\tbazel-clean\tbazel clean\n", .{});
    try stdout.print("COMMAND\tbazel-build-all\tbazel build //...\n", .{});
    try stdout.print("COMMAND\tbazel-test-all\tbazel test //...\n", .{});
    if (info.primary_build) |command| {
        try stdout.print("COMMAND\tbazel-build\t{s}\n", .{command});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{command});
        try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
    }
    if (info.primary_run) |command| {
        try stdout.print("COMMAND\tbazel-run\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
    if (info.primary_test) |command| {
        try stdout.print("COMMAND\tbazel-test\t{s}\n", .{command});
        try stdout.print("COMMAND\ttest\t{s}\n", .{command});
        try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
    }
}

test "writeBuildOutput emits cmake primary target and discovered run path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build/bin");
    try tmp.dir.writeFile(.{ .sub_path = "build/bin/demo-app", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const cmake_path = try std.fs.path.join(allocator, &.{ root, "CMakeLists.txt" });
    defer allocator.free(cmake_path);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeBuildOutput(out.writer(allocator), allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = match_path,
    },
        \\project(demo-app)
        \\add_executable(${PROJECT_NAME} src/main.cpp)
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "TARGET\tdemo-app\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcmake-build-demo-app\tcmake --build build --target demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcmake-run-demo-app\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RUN_PATH\tdemo-app\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_TARGET\tdemo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN_PATH\t./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tclean\tcmake --build build --target clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tctest --test-dir build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tcmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tconfig\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tclean\tcmake --build build --target clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tdebug\tcmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trelease\tcmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tctest --test-dir build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tinstall\tcmake --build build --target install\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tcmake --build build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tcmake --build build --target demo-app && ./build/bin/demo-app\n") != null);
}

test "writeBuildOutput emits meson preferred command aliases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("build");
    try tmp.dir.writeFile(.{ .sub_path = "meson.build", .data =
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    });
    try tmp.dir.writeFile(.{ .sub_path = "build/build.ninja", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "build/demo-app", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const meson_path = try std.fs.path.join(allocator, &.{ root, "meson.build" });
    defer allocator.free(meson_path);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeBuildOutput(out.writer(allocator), allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    },
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    ));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tsetup\tmeson setup build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tsetup\tmeson setup build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tclean\tmeson compile -C build --clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tmeson test -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tmeson compile -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tclean\tmeson compile -C build --clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tmeson test -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tinstall\tmeson install -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tmeson compile -C build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tmeson compile -C build demo-app && ./build/demo-app\n") != null);
}

test "writeBuildOutput emits bazel commands and primary targets" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeBuildOutput(out.writer(allocator), allocator, .{
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-run-main\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-test-main_test\tbazel test //app:main_test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-query\tbazel query $zignite_args\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-clean\tbazel clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build-all\tbazel build //...\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-test-all\tbazel test //...\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-run\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BUILD\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tbazel run //app:main\n") != null);
}

test "writeBuildOutput emits bazel workspace commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app");
    try tmp.dir.writeFile(.{ .sub_path = "app/BUILD.bazel", .data =
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
    try tmp.dir.writeFile(.{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });

    const workspace_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_root);
    const match_path = try tmp.dir.realpathAlloc(allocator, "app/main.cc");
    defer allocator.free(match_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeBuildOutput(out.writer(allocator), allocator, .{
        .kind = .bazel_workspace,
        .path = workspace_root,
        .match_path = match_path,
    }, ""));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-run-main\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-test-main_test\tbazel test //app:main_test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-query\tbazel query $zignite_args\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-clean\tbazel clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build-all\tbazel build //...\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-test-all\tbazel test //...\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-build\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbazel-run\tbazel run //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BUILD\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tbazel run //app:main\n") != null);
}
