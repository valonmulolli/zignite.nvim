const std = @import("std");
const build_common = @import("../../build/common.zig");
const bazel = @import("../bazel.zig");
const cargo = @import("../cargo.zig");
const cmake = @import("../cmake.zig");
const common = @import("common.zig");
const gradle = @import("../gradle.zig");
const go_mod = @import("../go_mod.zig");
const go = @import("../go.zig");
const go_work = @import("../go_work.zig");
const project_io = @import("io.zig");
const make = @import("../make.zig");
const maven = @import("../maven.zig");
const meson = @import("../meson.zig");
const package_json = @import("../package_json.zig");
const pyproject = @import("../pyproject.zig");
const types = @import("types.zig");

const Options = types.Options;

fn writeMavenOutput(stdout: anytype, allocator: std.mem.Allocator, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);
    try maven.parseGoals(allocator, contents, &names);

    try stdout.print("COMMAND\tmvn-build\tmvn compile\n", .{});
    try stdout.print("COMMAND\tmvn-test\tmvn test\n", .{});
    try stdout.print("COMMAND\tmvn-package\tmvn package\n", .{});
    try stdout.print("COMMAND\tbuild\tmvn compile\n", .{});
    try stdout.print("COMMAND\ttest\tmvn test\n", .{});
    try stdout.print("PREFERRED\tbuild\tmvn compile\n", .{});
    try stdout.print("PREFERRED\ttest\tmvn test\n", .{});

    var run_command: ?[]const u8 = null;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "spring-boot:run")) {
            run_command = "mvn spring-boot:run";
            break;
        }
        if (run_command == null and std.mem.eql(u8, name, "exec:java")) {
            run_command = "mvn exec:java";
        }
    }

    if (run_command) |command| {
        try stdout.print("COMMAND\tmvn-run\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
}

fn writeGradleOutput(stdout: anytype, allocator: std.mem.Allocator, build_file_path: []const u8, contents: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer common.freeOwnedNameList(allocator, names.items);
    try gradle.parseTasks(allocator, contents, &names);

    const root = std.fs.path.dirname(build_file_path) orelse "";
    const wrapper_path = try std.fs.path.join(allocator, &.{ root, "gradlew" });
    defer allocator.free(wrapper_path);
    const prefix: []const u8 = if (project_io.pathExists(wrapper_path)) "./gradlew" else "gradle";

    const build_command = try std.fmt.allocPrint(allocator, "{s} build", .{prefix});
    defer allocator.free(build_command);
    const test_command = try std.fmt.allocPrint(allocator, "{s} test", .{prefix});
    defer allocator.free(test_command);
    const clean_command = try std.fmt.allocPrint(allocator, "{s} clean", .{prefix});
    defer allocator.free(clean_command);

    try stdout.print("COMMAND\tgradle-build\t{s}\n", .{build_command});
    try stdout.print("COMMAND\tgradle-test\t{s}\n", .{test_command});
    try stdout.print("COMMAND\tgradle-clean\t{s}\n", .{clean_command});
    try stdout.print("COMMAND\tbuild\t{s}\n", .{build_command});
    try stdout.print("COMMAND\ttest\t{s}\n", .{test_command});
    try stdout.print("COMMAND\tclean\t{s}\n", .{clean_command});
    try stdout.print("PREFERRED\tbuild\t{s}\n", .{build_command});
    try stdout.print("PREFERRED\ttest\t{s}\n", .{test_command});

    var run_task: ?[]const u8 = null;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "bootRun")) {
            run_task = "bootRun";
            break;
        }
        if (run_task == null and std.mem.eql(u8, name, "run")) {
            run_task = "run";
        }
    }

    if (run_task) |task| {
        const run_command = try std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, task });
        defer allocator.free(run_command);
        try stdout.print("COMMAND\tgradle-run\t{s}\n", .{run_command});
        try stdout.print("COMMAND\trun\t{s}\n", .{run_command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{run_command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{run_command});
    }
}

fn writeCargoOutput(stdout: anytype, allocator: std.mem.Allocator, cargo_toml_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const items = try cargo.parseTargets(allocator, contents, cargo_toml_path, match_path);
    defer cargo.freeOwnedTargets(allocator, items);
    var primary_bin: ?[]const u8 = null;
    for (items) |item| {
        if (item.matched and primary_bin == null) {
            primary_bin = item.name;
        }
        try stdout.print("BIN\t{s}\t{d}\n", .{ item.name, if (item.matched) @as(u8, 1) else @as(u8, 0) });
        const quoted = try common.quoteShellArgAlloc(allocator, item.name);
        defer allocator.free(quoted);
        try stdout.print("COMMAND\tcargo-build-{s}\tcargo build --bin {s}\n", .{ item.name, quoted });
        try stdout.print("COMMAND\tcargo-run-{s}\tcargo run --bin {s}\n", .{ item.name, quoted });
        try stdout.print("COMMAND\tcargo-test-{s}\tcargo test --bin {s}\n", .{ item.name, quoted });
    }
    if (primary_bin == null and items.len > 0) {
        primary_bin = items[0].name;
    }
    if (primary_bin) |name| {
        const quoted = try common.quoteShellArgAlloc(allocator, name);
        defer allocator.free(quoted);

        try stdout.print("PRIMARY_BIN\t{s}\n", .{name});
        try stdout.print("PRIMARY_RUN\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("PRIMARY_RELEASE_RUN\tcargo run --release --bin {s}\n", .{quoted});
        try stdout.print("COMMAND\trun\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("COMMAND\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
        try stdout.print("PREFERRED\trun\tcargo run --bin {s}\n", .{quoted});
        try stdout.print("PREFERRED\trelease-run\tcargo run --release --bin {s}\n", .{quoted});
    }
}

fn writeGoOutput(stdout: anytype, allocator: std.mem.Allocator, project_path: []const u8, contents: []const u8, match_path: ?[]const u8) !void {
    const info = try go.parseInfo(allocator, contents, project_path, match_path);
    defer go.freeOwnedInfo(allocator, info);

    if (info.module_name) |name| {
        try stdout.print("MODULE\t{s}\n", .{name});
    }
    if (info.primary_selector) |selector| {
        try stdout.print("PRIMARY_SELECTOR\t{s}\n", .{selector});
    }
    if (info.primary_build) |command| {
        try stdout.print("COMMAND\tgo-build-package\t{s}\n", .{command});
        try stdout.print("COMMAND\tbuild\t{s}\n", .{command});
        try stdout.print("PRIMARY_BUILD\t{s}\n", .{command});
        try stdout.print("PREFERRED\tbuild\t{s}\n", .{command});
    }
    if (info.primary_run) |command| {
        try stdout.print("COMMAND\tgo-run-package\t{s}\n", .{command});
        try stdout.print("COMMAND\trun\t{s}\n", .{command});
        try stdout.print("PRIMARY_RUN\t{s}\n", .{command});
        try stdout.print("PREFERRED\trun\t{s}\n", .{command});
    }
    if (info.primary_test) |command| {
        try stdout.print("COMMAND\tgo-test-package\t{s}\n", .{command});
        try stdout.print("COMMAND\ttest\t{s}\n", .{command});
        try stdout.print("PRIMARY_TEST\t{s}\n", .{command});
        try stdout.print("PREFERRED\ttest\t{s}\n", .{command});
    }
}

pub fn writeDirectOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, contents: []const u8) !void {
    switch (options.kind) {
        .cargo => return writeCargoOutput(stdout, allocator, options.path, contents, options.match_path),
        .go => return writeGoOutput(stdout, allocator, options.path, contents, options.match_path),
        .maven => return writeMavenOutput(stdout, allocator, contents),
        .gradle => return writeGradleOutput(stdout, allocator, options.path, contents),
        .make, .make_auto => {
            var names: std.ArrayList([]u8) = .empty;
            defer common.freeOwnedNameList(allocator, names.items);
            try make.parseTargets(allocator, contents, &names);
            for (names.items) |name| {
                try stdout.print("COMMAND\t{s}\tmake {s}\n", .{ name, name });
            }
            return;
        },
        .package_json, .package_json_auto => {
            var names: std.ArrayList([]u8) = .empty;
            defer common.freeOwnedNameList(allocator, names.items);
            try package_json.parseScripts(allocator, contents, &names);
            const manager = options.package_manager orelse "npm";
            for (names.items) |name| {
                const command = try package_json.formatScriptCommandAlloc(allocator, manager, name);
                defer allocator.free(command);
                try stdout.print("COMMAND\t{s}\t{s}\n", .{ name, command });
            }
            return;
        },
        .cmake => {
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
            return;
        },
        .meson => {
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
            return;
        },
        .pyproject => {
            var names: std.ArrayList([]u8) = .empty;
            defer common.freeOwnedNameList(allocator, names.items);
            try pyproject.parseTools(allocator, contents, &names);
            for (names.items) |name| {
                try stdout.print("TOOL\t{s}\n", .{name});
            }
            return;
        },
        .go_mod => {
            const maybe_name = try go_mod.parseModuleName(allocator, contents);
            defer if (maybe_name) |name| allocator.free(name);
            if (maybe_name) |name| {
                try stdout.print("MODULE\t{s}\n", .{name});
            }
            return;
        },
        .go_work => {
            const items = try go_work.parseUses(allocator, contents, options.path, options.match_path);
            defer go_work.freeOwnedUses(allocator, items);
            for (items) |item| {
                try stdout.print("USE\t{s}\t{d}\n", .{ item.path, if (item.matched) @as(u8, 1) else @as(u8, 0) });
            }
            return;
        },
        .bazel => {
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
            return;
        },
        .bazel_workspace => {
            const info = try bazel.buildWorkspaceCommandInfo(allocator, options.path, options.match_path);
            defer bazel.freeOwnedCommandInfo(allocator, info);

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
            return;
        },
        else => return error.InvalidProjectParseKind,
    }
}

test "writeDirectOutput emits cargo primary run metadata with quoted bin names" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .cargo,
        .path = "/tmp/rustproj/Cargo.toml",
        .match_path = "/tmp/rustproj/src/bin/demo's-tool.rs",
    },
        \\[package]
        \\name = "demo"
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "BIN\tdemo's-tool\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BIN\tdemo's-tool\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RELEASE_RUN\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tcargo run --bin 'demo'\"'\"'s-tool'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trelease-run\tcargo run --release --bin 'demo'\"'\"'s-tool'\n") != null);
}

test "writeDirectOutput emits make command records" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .make,
        .path = "/tmp/Makefile",
    },
        "all:\n\t@echo ok\nclean:\n\t@rm -f out\nbench:\n\t@echo bench\n",
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tall\tmake all\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tclean\tmake clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbench\tmake bench\n") != null);
}

test "writeDirectOutput emits package script command records with package manager" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .package_json,
        .path = "/tmp/package.json",
        .package_manager = "pnpm",
    },
        \\{ "scripts": { "dev": "vite", "build": "vite build" } }
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tdev\tpnpm run dev\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tpnpm run build\n") != null);
}

test "writeDirectOutput emits go primary command metadata" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .go,
        .path = "/tmp/go.mod",
        .match_path = "/tmp/cmd/api/main.go",
    },
        \\module github.com/example/demo
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "MODULE\tgithub.com/example/demo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_SELECTOR\t./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_BUILD\tgo build ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tgo run ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_TEST\tgo test ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tgo build ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tgo run ./cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tgo test ./cmd/api\n") != null);
}

test "writeDirectOutput emits maven command records" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .maven,
        .path = "/tmp/pom.xml",
    },
        \\| mvn compile
        \\| mvn test
        \\| mvn spring-boot:run
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-build\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-test\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-package\tmvn package\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tmvn-run\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\tmvn spring-boot:run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\tmvn compile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\tmvn test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\tmvn spring-boot:run\n") != null);
}

test "writeDirectOutput emits gradle command records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const gradle_path = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
    defer allocator.free(gradle_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .gradle,
        .path = gradle_path,
    },
        \\plugins {
        \\    id("application")
        \\    id("org.springframework.boot") version "3.5.0"
        \\}
    );

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-test\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-clean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-run\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tclean\t./gradlew clean\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_RUN\t./gradlew bootRun\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\tbuild\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\ttest\t./gradlew test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PREFERRED\trun\t./gradlew bootRun\n") != null);
}

test "writeDirectOutput emits cmake primary target and discovered run path" {
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

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = match_path,
    },
        \\project(demo-app)
        \\add_executable(${PROJECT_NAME} src/main.cpp)
    );

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

test "writeDirectOutput emits meson preferred command aliases" {
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

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = match_path,
    },
        \\project('demo', 'cpp')
        \\executable('demo-app', 'src/main.cpp')
    );

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

test "writeDirectOutput emits bazel commands and primary targets" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try writeDirectOutput(out.writer(allocator), allocator, .{
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
    );

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

test "writeDirectOutput emits bazel workspace commands" {
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

    try writeDirectOutput(out.writer(allocator), allocator, .{
        .kind = .bazel_workspace,
        .path = workspace_root,
        .match_path = match_path,
    }, "");

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
