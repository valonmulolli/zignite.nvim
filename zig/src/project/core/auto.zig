const std = @import("std");
const cache = @import("cache.zig");
const direct = @import("auto/direct.zig");
const types = @import("types.zig");
const write = @import("auto/write.zig");

const Options = types.Options;

pub fn writeAutoOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    if (comptime @import("builtin").is_test) {
        return writeAutoOutputWithIO(std.testing.io, stdout, allocator, options);
    }
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return writeAutoOutputWithIO(threaded.io(), stdout, allocator, options);
}

pub fn writeAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    switch (options.kind) {
        .system => return try write.writeSystemQueryOutputWithIO(io, stdout, allocator, options),
        .jvm_auto => return try write.writeJVMAutoWithIO(io, stdout, allocator, options),
        .c_family_auto => return try write.writeCFamilyAutoWithIO(io, stdout, allocator, options),
        .cargo_auto => return try direct.writeCargoAutoOutputWithIO(io, stdout, allocator, options),
        .zig_auto => return try direct.writeZigAutoOutputWithIO(io, stdout, allocator, options),
        .go_auto => return try direct.writeGoAutoOutputWithIO(io, stdout, allocator, options),
        .python_auto => return try write.writePythonAutoWithIO(io, stdout, allocator, options),
        .cmake_auto => return try direct.writeCMakeAutoOutputWithIO(io, stdout, allocator, options),
        .meson_auto => return try direct.writeMesonAutoOutputWithIO(io, stdout, allocator, options),
        .bazel_auto => return try write.writeBazelAutoWithIO(io, stdout, allocator, options),
        else => return false,
    }
}

test "writeAutoOutput emits cargo-auto records from source path" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "demo"
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "bin", "tool.rs" });
    defer allocator.free(filepath);

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .cargo_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "BIN\ttool\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tcargo run --bin 'tool'\n") != null);
}

test "writeAutoOutput emits go-auto records preferring go.work" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "services/api/cmd/api");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "go.work", .data =
        \\go 1.23.0
        \\
        \\use ./services/api
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "services/api/go.mod", .data =
        \\module github.com/example/api
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "services", "api", "cmd", "api", "main.go" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .go_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "ROOT\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "SYSTEM\tgo\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "MODULE\tgithub.com/example/api\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_SELECTOR\t./services/api/cmd/api\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tgo run './services/api/cmd/api'\n") != null);
}

test "writeAutoOutput emits make-backed commands for go projects with Makefile" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "go.mod", .data =
        \\module github.com/example/hello
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.go", .data =
        \\package main
        \\
        \\func main() {}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data =
        \\.PHONY: build run test clean fmt
        \\build:
        \\\tgo build -o hello .
        \\run:
        \\\tgo run .
        \\test:
        \\\tgo test ./...
        \\fmt:
        \\\tgo fmt ./...
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "main.go", allocator);
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .go_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "ROOT\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "SYSTEM\tmake\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tmake build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tmake run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tmake test\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tfmt\tmake fmt\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_SELECTOR\t") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgo-run-package\t") == null);
}

test "writeAutoOutput emits zig-auto records from build steps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data =
        \\pub fn main() void {}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const module = b.createModule(.{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const exe = b.addExecutable(.{
        \\        .name = "demo",
        \\        .root_module = module,
        \\    });
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run_cmd.step);
        \\
        \\    const watch_step = b.step("watch", "Watch sources");
        \\    watch_step.dependOn(&run_cmd.step);
        \\
        \\    const bundle_step = b.step("bundle", "Build release bundle");
        \\    bundle_step.dependOn(&run_cmd.step);
        \\}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .zig_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "ROOT\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "SYSTEM\tzig\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tzig build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tzig build run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\twatch\tzig build watch\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbundle\tzig build bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tzig build watch\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trelease\tzig build bundle\n") != null);
}

test "writeAutoOutput keeps zig root and base build command when step detection fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data =
        \\pub fn main() void {}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data =
        \\this is not valid zig
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.zig" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .zig_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "ROOT\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "SYSTEM\tzig\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tzig build\n") != null);
}

test "writeAutoOutput emits python-auto uv commands from source path" {
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

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .python_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tuv run -m main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\ttest\tuv run pytest\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tinstall\tuv sync\n") != null);
}

test "writeAutoOutput emits jvm-auto records for Gradle projects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/main/java/com/example");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.gradle.kts", .data =
        \\plugins {
        \\    application
        \\}
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gradlew", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main", "java", "com", "example", "App.java" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .jvm_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tgradle-build\t./gradlew build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\t./gradlew build\n") != null);
}

test "writeAutoOutput refreshes cached c-family-auto output after Makefile changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    cache.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "run:\n\t@echo run\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();

    try std.testing.expect(try writeAutoOutput(&first.writer, allocator, .{
        .kind = .c_family_auto,
        .path = filepath,
        .project_root = root,
    }));
    try std.testing.expect(std.mem.find(u8, first.written(), "COMMAND\trun\tmake run\n") != null);
    try std.testing.expect(std.mem.find(u8, first.written(), "COMMAND\ttest\tmake test\n") == null);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "run:\n\t@echo run\ntest:\n\t@echo test\n" });

    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();

    try std.testing.expect(try writeAutoOutput(&second.writer, allocator, .{
        .kind = .c_family_auto,
        .path = filepath,
        .project_root = root,
    }));
    try std.testing.expect(std.mem.find(u8, second.written(), "COMMAND\trun\tmake run\n") != null);
    try std.testing.expect(std.mem.find(u8, second.written(), "COMMAND\ttest\tmake test\n") != null);
}

test "writeAutoOutput refreshes cached bazel-auto output after BUILD changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    cache.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.cc", allocator);
    defer allocator.free(filepath);

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();

    try std.testing.expect(try writeAutoOutput(&first.writer, allocator, .{
        .kind = .bazel_auto,
        .path = filepath,
    }));
    try std.testing.expect(std.mem.find(u8, first.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, first.written(), "COMMAND\tbazel-test-app-main_test\tbazel test //app:main_test\n") == null);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake);
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

    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();

    try std.testing.expect(try writeAutoOutput(&second.writer, allocator, .{
        .kind = .bazel_auto,
        .path = filepath,
    }));
    try std.testing.expect(std.mem.find(u8, second.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, second.written(), "COMMAND\tbazel-test-app-main_test\tbazel test //app:main_test\n") != null);
}

test "writeAutoOutput emits c-family auto commands for nested cmake source" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.createDirPath(std.testing.io, "build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data =
        \\project(app)
        \\add_executable(app src/nested/main.cpp)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/CMakeCache.txt", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const match_path = try std.fs.path.join(allocator, &.{ root, "src", "nested", "main.cpp" });
    defer allocator.free(match_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .c_family_auto,
        .path = match_path,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "SYSTEM\tcmake\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "ROOT\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcmake-build-app\tcmake --build build --target app\n") != null);
}

test "writeAutoOutput emits c-family auto bazel commands for source files" {
    const allocator = std.testing.allocator;
    cache.resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
    });

    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "app/main.cc", allocator);
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try std.testing.expect(try writeAutoOutput(&out.writer, allocator, .{
        .kind = .c_family_auto,
        .path = filepath,
    }));

    try std.testing.expect(std.mem.find(u8, out.written(), "SYSTEM\tbazel\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build-app-main\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbazel-build\tbazel build //app:main\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PRIMARY_BUILD\tbazel build //app:main\n") != null);
}
