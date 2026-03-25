const std = @import("std");
const build_system = @import("../../build/system.zig");
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

            const root = result.root orelse return true;
            const system = result.system orelse return true;

            if (std.mem.eql(u8, system, "maven")) {
                const pom_path = try std.fs.path.join(allocator, &.{ root, "pom.xml" });
                defer allocator.free(pom_path);
                const pom_contents = try common.readFileAlloc(allocator, pom_path);
                defer allocator.free(pom_contents);
                try emit.writeDirectOutput(stdout, allocator, .{ .kind = .maven, .path = pom_path }, pom_contents);
                return true;
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
                    return true;

                const build_contents = try common.readFileAlloc(allocator, build_file);
                defer allocator.free(build_contents);
                try emit.writeDirectOutput(stdout, allocator, .{ .kind = .gradle, .path = build_file }, build_contents);
            }
            return true;
        },
        .c_family_auto => {
            const result = try build_system.detect(allocator, .c_family, options.path, options.project_root);
            defer build_system.freeOwnedResult(allocator, result);

            try writeSystemResult(stdout, result);
            const system = result.system orelse return true;

            if (std.mem.eql(u8, system, "make")) {
                const auto_contents = try project_io.readProjectFile(allocator, .make_auto, options.path);
                defer allocator.free(auto_contents);
                try emit.writeDirectOutput(stdout, allocator, .{
                    .kind = .make_auto,
                    .path = options.path,
                    .project_root = result.root,
                }, auto_contents);
                return true;
            }

            if (std.mem.eql(u8, system, "cmake")) {
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
            }

            if (std.mem.eql(u8, system, "meson")) {
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
            }

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
            const pyproject_path = (try project_io.findParentFileAlloc(allocator, options.path, "pyproject.toml", 12)) orelse return true;
            defer allocator.free(pyproject_path);
            const pyproject_contents = try common.readFileAlloc(allocator, pyproject_path);
            defer allocator.free(pyproject_contents);
            try emit.writeDirectOutput(stdout, allocator, .{
                .kind = .python_auto,
                .path = pyproject_path,
            }, pyproject_contents);
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
            const root = result.root orelse return true;
            try emit.writeDirectOutput(stdout, allocator, .{
                .kind = .bazel_workspace,
                .path = root,
                .match_path = options.match_path orelse options.path,
            }, "");
            return true;
        },
        else => return false,
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
