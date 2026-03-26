const std = @import("std");
const build_system = @import("../../build/system.zig");
const cache = @import("cache.zig");
const common = @import("common.zig");
const emit = @import("emit.zig");
const project_io = @import("io.zig");
const types = @import("types.zig");

const Options = types.Options;

fn writeSystemResult(stdout: anytype, result: build_system.Result) !void {
    if (result.root) |root| {
        try stdout.print("ROOT\t{s}\n", .{root});
    }
    if (result.system) |name| {
        try stdout.print("SYSTEM\t{s}\n", .{name});
    }
    if (result.build_ready) |ready| {
        try stdout.print("BUILD_READY\t{d}\n", .{if (ready) @as(u8, 1) else @as(u8, 0)});
    }
    for (result.commands) |entry| {
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
}

pub fn writeAutoOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    switch (options.kind) {
        .system => {
            const query = options.query orelse return error.MissingSystemQuery;
            const result = try build_system.detect(allocator, query, options.path, options.project_root);
            defer build_system.freeOwnedResult(allocator, result);
            try writeSystemResult(stdout, result);
            return true;
        },
        .jvm_auto => {
            const result = try build_system.detect(allocator, .jvm_root, options.path, options.project_root);
            defer build_system.freeOwnedResult(allocator, result);
            if (try buildJVMAutoSignatureAlloc(allocator, result)) |signature| {
                defer allocator.free(signature);
                if (try cache.getAutoOutput(options, signature)) |cached_output| {
                    try stdout.writeAll(cached_output);
                    return true;
                }

                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(allocator);
                try writeJVMAutoOutput(out.writer(allocator), allocator, result);
                const output = try out.toOwnedSlice(allocator);
                defer allocator.free(output);

                try cache.storeAutoOutput(options, signature, output);
                try stdout.writeAll(output);
                return true;
            }

            try writeJVMAutoOutput(stdout, allocator, result);
            return true;
        },
        .c_family_auto => {
            const result = try build_system.detect(allocator, .c_family, options.path, options.project_root);
            defer build_system.freeOwnedResult(allocator, result);
            if (try buildCFamilyAutoSignatureAlloc(allocator, result)) |signature| {
                defer allocator.free(signature);

                if (try cache.getAutoOutput(options, signature)) |cached_output| {
                    try stdout.writeAll(cached_output);
                    return true;
                }

                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(allocator);
                try writeCFamilyAutoOutput(out.writer(allocator), allocator, options, result);
                const output = try out.toOwnedSlice(allocator);
                defer allocator.free(output);

                try cache.storeAutoOutput(options, signature, output);
                try stdout.writeAll(output);
                return true;
            }

            try writeCFamilyAutoOutput(stdout, allocator, options, result);
            return true;
        },
        .cargo_auto => {
            const cargo_toml_path = (try project_io.findParentFileAlloc(allocator, options.path, "Cargo.toml", 12)) orelse return true;
            defer allocator.free(cargo_toml_path);
            const cargo_contents = try common.readFileAlloc(allocator, cargo_toml_path);
            defer allocator.free(cargo_contents);
            try emit.writeDirectOutput(stdout, allocator, .{
                .kind = .cargo,
                .path = cargo_toml_path,
                .match_path = options.path,
            }, cargo_contents);
            return true;
        },
        .go_auto => {
            const go_work_path = try project_io.findParentFileAlloc(allocator, options.path, "go.work", 10);
            if (go_work_path) |project_path| {
                defer allocator.free(project_path);
                const go_work_contents = try common.readFileAlloc(allocator, project_path);
                defer allocator.free(go_work_contents);
                try emit.writeDirectOutput(stdout, allocator, .{
                    .kind = .go,
                    .path = project_path,
                    .match_path = options.path,
                }, go_work_contents);
                return true;
            }

            const go_mod_path = (try project_io.findParentFileAlloc(allocator, options.path, "go.mod", 10)) orelse return true;
            defer allocator.free(go_mod_path);
            const go_mod_contents = try common.readFileAlloc(allocator, go_mod_path);
            defer allocator.free(go_mod_contents);
            try emit.writeDirectOutput(stdout, allocator, .{
                .kind = .go,
                .path = go_mod_path,
                .match_path = options.path,
            }, go_mod_contents);
            return true;
        },
        .python_auto => {
            const result = try build_system.detect(allocator, .python_root, options.path, options.project_root);
            defer build_system.freeOwnedResult(allocator, result);
            if (try buildPythonAutoSignatureAlloc(allocator, result)) |signature| {
                defer allocator.free(signature);
                if (try cache.getAutoOutput(options, signature)) |cached_output| {
                    try stdout.writeAll(cached_output);
                    return true;
                }

                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(allocator);
                try writePythonAutoOutput(out.writer(allocator), allocator, options);
                const output = try out.toOwnedSlice(allocator);
                defer allocator.free(output);

                try cache.storeAutoOutput(options, signature, output);
                try stdout.writeAll(output);
                return true;
            }

            try writePythonAutoOutput(stdout, allocator, options);
            return true;
        },
        .cmake_auto => {
            const cmake_path = (try project_io.findParentFileAlloc(allocator, options.path, "CMakeLists.txt", 12)) orelse return true;
            defer allocator.free(cmake_path);
            const cmake_contents = try common.readFileAlloc(allocator, cmake_path);
            defer allocator.free(cmake_contents);
            try emit.writeDirectOutput(stdout, allocator, .{
                .kind = .cmake,
                .path = cmake_path,
                .match_path = options.match_path orelse options.path,
            }, cmake_contents);
            return true;
        },
        .meson_auto => {
            const meson_path = (try project_io.findParentFileAlloc(allocator, options.path, "meson.build", 12)) orelse return true;
            defer allocator.free(meson_path);
            const meson_contents = try common.readFileAlloc(allocator, meson_path);
            defer allocator.free(meson_contents);
            try emit.writeDirectOutput(stdout, allocator, .{
                .kind = .meson,
                .path = meson_path,
                .match_path = options.match_path orelse options.path,
            }, meson_contents);
            return true;
        },
        .bazel_auto => {
            const result = try build_system.detect(allocator, .bazel_root, options.path, options.project_root);
            defer build_system.freeOwnedResult(allocator, result);
            if (try buildBazelAutoSignatureAlloc(allocator, options, result)) |signature| {
                defer allocator.free(signature);
                if (try cache.getAutoOutput(options, signature)) |cached_output| {
                    try stdout.writeAll(cached_output);
                    return true;
                }

                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(allocator);
                try writeBazelAutoOutput(out.writer(allocator), allocator, options, result);
                const output = try out.toOwnedSlice(allocator);
                defer allocator.free(output);

                try cache.storeAutoOutput(options, signature, output);
                try stdout.writeAll(output);
                return true;
            }

            try writeBazelAutoOutput(stdout, allocator, options, result);
            return true;
        },
        else => return false,
    }
}

fn writeJVMAutoOutput(stdout: anytype, allocator: std.mem.Allocator, result: build_system.Result) !void {
    const root = result.root orelse return;
    const system = result.system orelse return;

    if (std.mem.eql(u8, system, "maven")) {
        const pom_path = try std.fs.path.join(allocator, &.{ root, "pom.xml" });
        defer allocator.free(pom_path);
        const pom_contents = try common.readFileAlloc(allocator, pom_path);
        defer allocator.free(pom_contents);
        try emit.writeDirectOutput(stdout, allocator, .{ .kind = .maven, .path = pom_path }, pom_contents);
        return;
    }

    if (std.mem.eql(u8, system, "gradle")) {
        const gradle_kts = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
        defer allocator.free(gradle_kts);
        const gradle_groovy = try std.fs.path.join(allocator, &.{ root, "build.gradle" });
        defer allocator.free(gradle_groovy);

        const build_file = if (project_io.pathExists(gradle_kts))
            gradle_kts
        else if (project_io.pathExists(gradle_groovy))
            gradle_groovy
        else
            return;

        const build_contents = try common.readFileAlloc(allocator, build_file);
        defer allocator.free(build_contents);
        try emit.writeDirectOutput(stdout, allocator, .{ .kind = .gradle, .path = build_file }, build_contents);
    }
}

fn writeCFamilyAutoOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, result: build_system.Result) !void {
    try writeSystemResult(stdout, result);
    const system = result.system orelse return;

    if (std.mem.eql(u8, system, "make")) {
        const auto_contents = try project_io.readProjectFile(allocator, .make_auto, options.path);
        defer allocator.free(auto_contents);
        try emit.writeDirectOutput(stdout, allocator, .{
            .kind = .make_auto,
            .path = options.path,
            .project_root = result.root,
        }, auto_contents);
        return;
    }

    if (std.mem.eql(u8, system, "cmake")) {
        const cmake_path = (try project_io.findParentFileAlloc(allocator, options.path, "CMakeLists.txt", 12)) orelse return;
        defer allocator.free(cmake_path);
        const cmake_contents = try common.readFileAlloc(allocator, cmake_path);
        defer allocator.free(cmake_contents);
        try emit.writeDirectOutput(stdout, allocator, .{
            .kind = .cmake,
            .path = cmake_path,
            .match_path = options.match_path orelse options.path,
        }, cmake_contents);
        return;
    }

    if (std.mem.eql(u8, system, "meson")) {
        const meson_path = (try project_io.findParentFileAlloc(allocator, options.path, "meson.build", 12)) orelse return;
        defer allocator.free(meson_path);
        const meson_contents = try common.readFileAlloc(allocator, meson_path);
        defer allocator.free(meson_contents);
        try emit.writeDirectOutput(stdout, allocator, .{
            .kind = .meson,
            .path = meson_path,
            .match_path = options.match_path orelse options.path,
        }, meson_contents);
    }
}

fn writePythonAutoOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    const pyproject_path = (try project_io.findParentFileAlloc(allocator, options.path, "pyproject.toml", 12)) orelse return;
    defer allocator.free(pyproject_path);
    const pyproject_contents = try common.readFileAlloc(allocator, pyproject_path);
    defer allocator.free(pyproject_contents);
    try emit.writeDirectOutput(stdout, allocator, .{
        .kind = .python_auto,
        .path = pyproject_path,
    }, pyproject_contents);
}

fn writeBazelAutoOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, result: build_system.Result) !void {
    const root = result.root orelse return;
    try emit.writeDirectOutput(stdout, allocator, .{
        .kind = .bazel_workspace,
        .path = root,
        .match_path = options.match_path orelse options.path,
    }, "");
}

fn buildJVMAutoSignatureAlloc(allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    const system = result.system orelse return null;

    if (std.mem.eql(u8, system, "maven")) {
        return try buildMarkerSignatureAlloc(allocator, root, &.{"pom.xml"});
    }
    if (std.mem.eql(u8, system, "gradle")) {
        return try buildMarkerSignatureAlloc(
            allocator,
            root,
            &.{ "gradlew", "settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle" },
        );
    }

    return null;
}

fn buildCFamilyAutoSignatureAlloc(allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    const system = result.system orelse return null;

    if (std.mem.eql(u8, system, "make")) {
        return try buildMarkerSignatureAlloc(allocator, root, &.{"Makefile"});
    }
    if (std.mem.eql(u8, system, "cmake")) {
        return try buildMarkerSignatureAlloc(allocator, root, &.{ "CMakeLists.txt", "build/CMakeCache.txt" });
    }
    if (std.mem.eql(u8, system, "meson")) {
        return try buildMarkerSignatureAlloc(
            allocator,
            root,
            &.{ "meson.build", "build/build.ninja", "build/meson-private/coredata.dat" },
        );
    }

    return null;
}

fn buildPythonAutoSignatureAlloc(allocator: std.mem.Allocator, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    return try buildMarkerSignatureAlloc(allocator, root, &.{ "pyproject.toml", "uv.lock" });
}

fn buildBazelAutoSignatureAlloc(allocator: std.mem.Allocator, options: Options, result: build_system.Result) !?[]u8 {
    const root = result.root orelse return null;
    const match_path = options.match_path orelse options.path;

    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    const workspace_signature = try buildMarkerSignatureAlloc(
        allocator,
        root,
        &.{ "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" },
    );
    defer allocator.free(workspace_signature);
    try signature.appendSlice(allocator, workspace_signature);

    const normalized_root = try common.normalizePathAlloc(allocator, root);
    defer allocator.free(normalized_root);
    const normalized_match = try common.normalizePathAlloc(allocator, match_path);
    defer allocator.free(normalized_match);

    var current_dir = try allocator.dupe(u8, std.fs.path.dirname(normalized_match) orelse normalized_match);
    defer allocator.free(current_dir);

    while (current_dir.len > 0) {
        const build_bazel_path = try std.fs.path.join(allocator, &.{ current_dir, "BUILD.bazel" });
        defer allocator.free(build_bazel_path);
        const build_path = try std.fs.path.join(allocator, &.{ current_dir, "BUILD" });
        defer allocator.free(build_path);

        if (project_io.pathExists(build_bazel_path)) {
            try appendSignatureFile(allocator, &signature, build_bazel_path);
        } else if (project_io.pathExists(build_path)) {
            try appendSignatureFile(allocator, &signature, build_path);
        }

        if (std.mem.eql(u8, current_dir, normalized_root)) break;
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;

        allocator.free(current_dir);
        current_dir = try allocator.dupe(u8, parent);
    }

    return try signature.toOwnedSlice(allocator);
}

fn buildMarkerSignatureAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    markers: []const []const u8,
) ![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    for (markers, 0..) |marker, index| {
        if (index > 0) try signature.append(allocator, '|');
        try signature.appendSlice(allocator, marker);
        try signature.append(allocator, ':');

        const file_path = try std.fs.path.join(allocator, &.{ root, marker });
        defer allocator.free(file_path);

        const mtime_key = try fileMtimeKeyAlloc(allocator, file_path);
        defer if (mtime_key) |key| allocator.free(key);

        if (mtime_key) |key| {
            try signature.appendSlice(allocator, key);
        } else {
            try signature.appendSlice(allocator, "missing");
        }
    }

    return try signature.toOwnedSlice(allocator);
}

fn fileMtimeKeyAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch return null
    else
        std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = try file.stat();
    return try std.fmt.allocPrint(allocator, "{d}:{d}", .{ stat.size, stat.mtime });
}

fn appendSignatureFile(
    allocator: std.mem.Allocator,
    signature: *std.ArrayList(u8),
    path: []const u8,
) !void {
    try signature.append(allocator, '|');
    try signature.appendSlice(allocator, path);
    try signature.append(allocator, ':');
    const mtime_key = try fileMtimeKeyAlloc(allocator, path);
    defer if (mtime_key) |key| allocator.free(key);
    if (mtime_key) |key| {
        try signature.appendSlice(allocator, key);
    } else {
        try signature.appendSlice(allocator, "missing");
    }
}

test "writeAutoOutput emits cargo-auto records from source path" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src/bin");
    try tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = 
        \\[package]
        \\name = "demo"
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "bin", "tool.rs" });
    defer allocator.free(filepath);

    try std.testing.expect(try writeAutoOutput(out.writer(allocator), allocator, .{
        .kind = .cargo_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "BIN\ttool\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tcargo run --bin 'tool'\n") != null);
}

test "writeAutoOutput emits go-auto records preferring go.work" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("services/api/cmd/api");
    try tmp.dir.writeFile(.{ .sub_path = "go.work", .data = 
        \\go 1.23.0
        \\
        \\use ./services/api
    });
    try tmp.dir.writeFile(.{ .sub_path = "services/api/go.mod", .data = 
        \\module github.com/example/api
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "services", "api", "cmd", "api", "main.go" });
    defer allocator.free(filepath);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(out.writer(allocator), allocator, .{
        .kind = .go_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "MODULE\tgithub.com/example/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "PRIMARY_SELECTOR\t./services/api/cmd/api\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tgo run ./services/api/cmd/api\n") != null);
}

test "writeAutoOutput emits python-auto uv commands from source path" {
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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(out.writer(allocator), allocator, .{
        .kind = .python_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\trun\tuv run -m main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\ttest\tuv run pytest\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tinstall\tuv sync\n") != null);
}

test "writeAutoOutput emits jvm-auto records for Gradle projects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/main/java/com/example");
    try tmp.dir.writeFile(.{ .sub_path = "build.gradle.kts", .data = 
        \\plugins {
        \\    application
        \\}
    });
    try tmp.dir.writeFile(.{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main", "java", "com", "example", "App.java" });
    defer allocator.free(filepath);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(out.writer(allocator), allocator, .{
        .kind = .jvm_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tbuild\t./gradlew build\n") != null);
}

test "writeAutoOutput refreshes cached c-family-auto output after Makefile changes" {
    const allocator = std.testing.allocator;
    cache.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "Makefile", .data = "run:\n\t@echo run\n" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(first.writer(allocator), allocator, .{
        .kind = .c_family_auto,
        .path = filepath,
        .project_root = root,
    }));
    try std.testing.expect(std.mem.indexOf(u8, first.items, "COMMAND\trun\tmake run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "COMMAND\ttest\tmake test\n") == null);

    std.time.sleep(2 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "Makefile", .data = "run:\n\t@echo run\ntest:\n\t@echo test\n" });

    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(second.writer(allocator), allocator, .{
        .kind = .c_family_auto,
        .path = filepath,
        .project_root = root,
    }));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "COMMAND\trun\tmake run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "COMMAND\ttest\tmake test\n") != null);
}

test "writeAutoOutput refreshes cached bazel-auto output after BUILD changes" {
    const allocator = std.testing.allocator;
    cache.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app");
    try tmp.dir.writeFile(.{ .sub_path = "MODULE.bazel", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });
    try tmp.dir.writeFile(.{ .sub_path = "app/BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
    });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const filepath = try tmp.dir.realpathAlloc(allocator, "app/main.cc");
    defer allocator.free(filepath);

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(first.writer(allocator), allocator, .{
        .kind = .bazel_auto,
        .path = filepath,
    }));
    try std.testing.expect(std.mem.indexOf(u8, first.items, "COMMAND\tbazel-build-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "COMMAND\tbazel-test-main_test\tbazel test //app:main_test\n") == null);

    std.time.sleep(2 * std.time.ns_per_ms);
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

    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(second.writer(allocator), allocator, .{
        .kind = .bazel_auto,
        .path = filepath,
    }));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "COMMAND\tbazel-build-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "COMMAND\tbazel-test-main_test\tbazel test //app:main_test\n") != null);
}

test "writeAutoOutput emits c-family auto commands for nested cmake source" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/nested");
    try tmp.dir.makePath("build");
    try tmp.dir.writeFile(.{ .sub_path = "CMakeLists.txt", .data = 
        \\project(app)
        \\add_executable(app src/nested/main.cpp)
    });
    try tmp.dir.writeFile(.{ .sub_path = "build/CMakeCache.txt", .data = "" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "nested", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try std.testing.expect(try writeAutoOutput(out.writer(allocator), allocator, .{
        .kind = .c_family_auto,
        .path = match_path,
    }));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "SYSTEM\tcmake\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "ROOT\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "COMMAND\tcmake-build-app\tcmake --build build --target app\n") != null);
}
