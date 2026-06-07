const std = @import("std");
const protocol_args = @import("../protocol/args.zig");
const frame = @import("../protocol/frame.zig");
const protocol_stdio = @import("../protocol/stdio.zig");
const command = @import("resolve/command.zig");
const detected = @import("resolve/detected.zig");
const protocol = @import("resolve/protocol.zig");
const selected = @import("resolve/selected.zig");
const serialize = @import("resolve/serialize.zig");
const types = @import("resolve/types.zig");
const action_state = @import("action/state.zig");

pub const Options = types.Options;
pub const ResolvedOutput = types.ResolvedOutput;
pub const resolveOutput = detected.resolveOutput;
pub const resolveOutputWithIO = detected.resolveOutputWithIO;
pub const resolveDetectedOutput = detected.resolveDetectedOutput;
pub const resolveDetectedOutputWithIO = detected.resolveDetectedOutputWithIO;
pub const findCommand = detected.findCommand;
pub const BUILD_RESOLVE_REQ_BEGIN = protocol.BUILD_RESOLVE_REQ_BEGIN;
pub const BUILD_RESOLVE_REQ_END = protocol.BUILD_RESOLVE_REQ_END;
pub const BUILD_RESOLVE_RES_BEGIN = protocol.BUILD_RESOLVE_RES_BEGIN;
pub const BUILD_RESOLVE_RES_END = protocol.BUILD_RESOLVE_RES_END;
pub const BUILD_RESOLVE_RES_ERR = protocol.BUILD_RESOLVE_RES_ERR;

pub fn parseArgs(args: []const []const u8) !Options {
    var common: protocol_args.CommonPathArgs = .{};
    var command_name: ?[]const u8 = null;
    var command_args: ?[]const u8 = null;

    for (args) |arg| {
        if (try protocol_args.parseCommonPathArg(&common, arg, "--build-resolve")) {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--command-name=")) {
            command_name = arg["--command-name=".len..];
        } else if (std.mem.startsWith(u8, arg, "--command-args=")) {
            command_args = arg["--command-args=".len..];
        } else {
            return error.InvalidBuildResolveFlag;
        }
    }

    return .{
        .path = common.path orelse return error.MissingBuildResolvePath,
        .filetype = common.filetype orelse return error.MissingBuildResolveFiletype,
        .command_name = command_name,
        .command_args = command_args,
        .project_root = common.project_root,
    };
}

pub fn runMode(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    return runModeWithEnviron(allocator, io, null, options);
}

pub fn runModeWithEnviron(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !void {
    var stdout_ctx: protocol_stdio.Stdout = .{};
    stdout_ctx.init(io);
    const stdout = stdout_ctx.io();
    try writeResolvedOutput(stdout, allocator, io, environ_map, options);
    try stdout.flush();
}

pub fn handleDaemonFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    reader: anytype,
    stdout: anytype,
    begin_line: []const u8,
) !void {
    const header = protocol.parseResolveDaemonBegin(begin_line) catch |err| {
        if (frame.parseRequestId(begin_line, BUILD_RESOLVE_REQ_BEGIN)) |request_id| {
            try frame.writeErrorResponse(
                stdout,
                BUILD_RESOLVE_RES_BEGIN,
                BUILD_RESOLVE_RES_ERR,
                BUILD_RESOLVE_RES_END,
                request_id,
                @errorName(err),
            );
            try stdout.flush();
            return;
        }
        return err;
    };

    const request_args = try frame.collectOwnedLinesUntilEnd(
        allocator,
        reader,
        protocol.BUILD_RESOLVE_MAX_LINE,
        BUILD_RESOLVE_REQ_END,
        header.request_id,
        .{
            .strip_leading_tab = true,
            .skip_empty = true,
            .max_bytes = 4 * 1024 * 1024,
        },
    );
    defer {
        for (request_args) |arg| allocator.free(arg);
        allocator.free(request_args);
    }

    try stdout.print("{s} {d}\n", .{ BUILD_RESOLVE_RES_BEGIN, header.request_id });
    const options = parseArgs(request_args);
    if (options) |parsed| {
        writeResolvedOutput(stdout, allocator, io, environ_map, parsed) catch |err| {
            try stdout.print("{s} {d} {s}\n", .{ BUILD_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
        };
    } else |err| {
        try stdout.print("{s} {d} {s}\n", .{ BUILD_RESOLVE_RES_ERR, header.request_id, @errorName(err) });
    }
    try stdout.print("{s} {d}\n", .{ BUILD_RESOLVE_RES_END, header.request_id });
    try stdout.flush();
}

fn writeResolvedOutput(
    stdout: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !void {
    if (options.command_name != null) {
        try writeResolvedCommandOutput(stdout, allocator, io, options);
        return;
    }

    var parsed_output = try detected.resolveOutputWithIO(io, allocator, options);
    defer parsed_output.deinit(allocator);

    if (parsed_output.preferred.items.len == 0) {
        try detected.appendImplicitPreferred(allocator, &parsed_output.preferred, parsed_output.commands.items);
    }
    const resolved_filetype = parsed_output.filetype orelse options.filetype;
    const live_names = [_][]const u8{"live"};
    const live_name = detected.findPreferredCommandName(parsed_output.preferred.items, parsed_output.commands.items, &live_names);
    const last_command_name = try action_state.getLastCommand(io, allocator, environ_map, resolved_filetype);
    try serialize.writeResolvedOutputJson(
        stdout,
        allocator,
        parsed_output,
        resolved_filetype,
        live_name,
        last_command_name,
    );
    try serialize.writeResolvedOutputLegacyHeader(stdout, parsed_output, resolved_filetype, last_command_name);
    try serialize.writeResolvedOutputLegacyCommands(stdout, allocator, resolved_filetype, parsed_output.commands.items);
    try serialize.writeResolvedOutputLegacyPreferred(stdout, parsed_output.preferred.items, live_name);
}

fn writeResolvedCommandOutput(stdout: anytype, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var resolved = try selected.resolveCommandExecutionWithIO(io, allocator, options);
    defer resolved.deinit(allocator);

    try serialize.writeResolvedCommandOutputJson(
        stdout,
        allocator,
        resolved.filetype,
        resolved.cwd,
        resolved.command_name,
        resolved.exec_command,
        resolved.exec_argv.items,
    );
    try serialize.writeResolvedCommandOutputLegacy(
        stdout,
        resolved.filetype,
        resolved.cwd,
        resolved.command_name,
        resolved.exec_command,
        resolved.exec_argv.items,
    );
}

const TestReader = frame.TestReader;

test "runMode merges synced configured build commands with backend commands" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"c":{"custom":"make custom"}},"detect":{"c_cpp_make":true}}
    , 7);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeLists.txt", .data = "project(demo)\nadd_executable(demo main.cpp)\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "main.cpp" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutput(&out.writer, allocator, std.testing.io, null, .{
        .path = filepath,
        .filetype = "c",
        .project_root = root,
    });

    try std.testing.expect(std.mem.find(u8, out.written(), "CONFIG_REVISION\t7\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tcustom\tmake custom\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tcmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build\n") != null);
    const json_idx = std.mem.find(u8, out.written(), "RESULT_JSON\t") orelse unreachable;
    const legacy_idx = std.mem.find(u8, out.written(), "COMMAND\tcustom\tmake custom\n") orelse unreachable;
    try std.testing.expect(json_idx < legacy_idx);
}

test "resolveOutput falls back to system commands when project auto output is unavailable" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{},"revision":11}
    , 11);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "uv.lock", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.py" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "python",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings(root, output.root.?);
    try std.testing.expectEqualStrings("python", output.system.?);
    try std.testing.expectEqualStrings("uv run -m main", detected.findCommand(output.commands.items, "run").?);
    try std.testing.expectEqualStrings("uv sync", detected.findCommand(output.commands.items, "install").?);
}

test "resolveOutput lets explicit configured python commands override builtin defaults" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"python":{"run":"python -m main","test":"pytest","install":"pip install -r requirements.txt"}},"detect":{},"revision":12}
    , 12);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "uv.lock", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.py" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "python",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings("python -m main", detected.findCommand(output.commands.items, "run").?);
    try std.testing.expectEqualStrings("pytest", detected.findCommand(output.commands.items, "test").?);
}

test "resolveOutput prefers Makefile commands for go projects" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{},"revision":13}
    , 13);

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

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "go",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings(root, output.root.?);
    try std.testing.expectEqualStrings("make", output.system.?);
    try std.testing.expectEqualStrings("make build", detected.findCommand(output.commands.items, "build").?);
    try std.testing.expectEqualStrings("make run", detected.findCommand(output.commands.items, "run").?);
    try std.testing.expectEqualStrings("make test", detected.findCommand(output.commands.items, "test").?);
    try std.testing.expectEqualStrings("make fmt", detected.findCommand(output.commands.items, "fmt").?);
    try std.testing.expectEqualStrings("go mod tidy", detected.findCommand(output.commands.items, "mod").?);
}

test "resolveOutput preserves explicit make targets from auto output" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{},"revision":23}
    , 23);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "build:\n\t@echo build\nbench:\n\t@echo bench\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "cpp",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings("make", output.system.?);
    try std.testing.expectEqualStrings("make build", detected.findCommand(output.commands.items, "build").?);
    try std.testing.expectEqualStrings("make bench", detected.findCommand(output.commands.items, "bench").?);
}

test "resolveOutput includes all configured c family commands regardless of detected system" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"c":{"build":"make","cmake-build":"cmake --build build","meson-build":"meson compile -C build"}},"detect":{"c_cpp_make":true},"revision":25}
    , 25);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "build:\n\t@echo build\nclean:\n\t@echo clean\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.c" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "c",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings("make", output.system.?);
    try std.testing.expectEqualStrings("make", detected.findCommand(output.commands.items, "build").?);
    try std.testing.expectEqualStrings("cmake --build build", detected.findCommand(output.commands.items, "cmake-build").?);
    try std.testing.expectEqualStrings("meson compile -C build", detected.findCommand(output.commands.items, "meson-build").?);
}

test "resolveOutput does not invent make run when no run target exists" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"c_cpp_make":true},"revision":24}
    , 24);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "build:\n\t@echo build\nclean:\n\t@echo clean\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.cpp" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "cpp",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings("make", output.system.?);
    try std.testing.expectEqualStrings("make build", detected.findCommand(output.commands.items, "build").?);
    try std.testing.expectEqualStrings("make clean", detected.findCommand(output.commands.items, "clean").?);
    try std.testing.expect(detected.findCommand(output.commands.items, "run") == null);
}

test "resolveOutput does not offer generic c family system commands without detected system" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"c_cpp_make":true},"revision":26}
    , 26);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.cpp", .data = "int main() { return 0; }\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.cpp", allocator);
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "cpp",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expect(output.system == null);
    try std.testing.expectEqual(@as(usize, 0), output.commands.items.len);
    try std.testing.expect(detected.findCommand(output.commands.items, "build") == null);
    try std.testing.expect(detected.findCommand(output.commands.items, "cmake-build") == null);
    try std.testing.expect(detected.findCommand(output.commands.items, "meson-build") == null);
}

test "resolveOutput suppresses non-bazel c/cpp defaults in bazel workspaces" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"c_cpp_make":true,"bazel_project":true},"revision":14}
    , 14);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "bazel_dep(name = \"rules_cc\", version = \"0.0.9\")\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/BUILD.bazel", .data =
        \\cc_binary(
        \\    name = "main",
        \\    srcs = ["main.cc"],
        \\)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/main.cc", .data = "int main() { return 0; }\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "app", "main.cc" });
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "cpp",
        .project_root = root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings("bazel", output.system.?);
    try std.testing.expectEqualStrings("bazel build //app:main", detected.findCommand(output.commands.items, "build").?);

    for (output.commands.items) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "cmake-"));
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "meson-"));
    }
}

test "resolveOutput prefers nested cmake project over outer bazel workspace" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"c_cpp_make":true,"bazel_project":true},"revision":15}
    , 15);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "third_party/demo/src");
    try tmp.dir.createDirPath(std.testing.io, "third_party/demo/build");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "MODULE.bazel", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "third_party/demo/CMakeLists.txt", .data =
        \\project(demo)
        \\add_executable(demo src/main.cpp)
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "third_party/demo/build/CMakeCache.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "third_party/demo/src/main.cpp", .data = "int main() { return 0; }\n" });

    const workspace_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(workspace_root);
    const nested_root = try tmp.dir.realPathFileAlloc(std.testing.io, "third_party/demo", allocator);
    defer allocator.free(nested_root);
    const filepath = try tmp.dir.realPathFileAlloc(std.testing.io, "third_party/demo/src/main.cpp", allocator);
    defer allocator.free(filepath);

    var output = try detected.resolveOutput(allocator, .{
        .path = filepath,
        .filetype = "cpp",
        .project_root = workspace_root,
    });
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings(nested_root, output.root.?);
    try std.testing.expectEqualStrings("cmake", output.system.?);
    try std.testing.expectEqualStrings("cmake --build build", detected.findCommand(output.commands.items, "build").?);
    try std.testing.expect(detected.findCommand(output.commands.items, "bazel-build-all") == null);
}

test "writeResolvedOutput emits implicit live preference when live command exists" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"js_package_scripts":true},"revision":13}
    , 13);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package.json", .data =
        \\{"scripts":{"dev":"vite","build":"vite build"}}
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.ts" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutput(&out.writer, allocator, std.testing.io, null, .{
        .path = filepath,
        .filetype = "typescript",
        .project_root = root,
    });

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tlive\t") != null);
}

test "writeResolvedOutput emits command ui metadata for placeholder commands" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"zig":{"fetch":"zig fetch $zignite_args"}},"detect":{},"revision":21}
    , 21);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *anyopaque) void {}\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutput(&out.writer, allocator, std.testing.io, null, .{
        .path = filepath,
        .filetype = "zig",
        .project_root = root,
    });

    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND_DISPLAY\tfetch\tzig fetch <args>\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND_ARGS_REQUIRED\tfetch\t1\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND_ARG_PROMPT\tfetch\tzig fetch url/path\n") != null);
}

test "writeResolvedOutput emits custom zig build steps and project root" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{},"detect":{"zig":true},"revision":23}
    , 23);

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

    try writeResolvedOutput(&out.writer, allocator, std.testing.io, null, .{
        .path = filepath,
        .filetype = "zig",
    });

    try std.testing.expect(std.mem.find(u8, out.written(), "ROOT\t") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbuild\tzig build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trun\tzig build run\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\twatch\tzig build watch\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tbundle\tzig build bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\tlive\tzig build watch\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "COMMAND\trelease\tzig build bundle\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED\tlive\tzig build watch\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "PREFERRED_NAME\tlive\tlive\n") != null);
}

test "writeResolvedOutput emits selected command execution metadata" {
    const allocator = std.testing.allocator;
    defer @import("../config/store.zig").reset();
    try @import("../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"rust":{"build":"cargo build"}},"detect":{},"revision":22}
    , 22);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "src", "main.rs" });
    defer allocator.free(filepath);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutput(&out.writer, allocator, std.testing.io, null, .{
        .path = filepath,
        .filetype = "rust",
        .project_root = root,
        .command_name = "build",
    });

    try std.testing.expect(std.mem.find(u8, out.written(), "NAME\trust: build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "EXEC_COMMAND\tcargo build\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"exec_command\":\"cargo build\"") != null);
    const json_idx = std.mem.find(u8, out.written(), "RESULT_JSON\t") orelse unreachable;
    const legacy_idx = std.mem.find(u8, out.written(), "EXEC_COMMAND\tcargo build\n") orelse unreachable;
    try std.testing.expect(json_idx < legacy_idx);
}

test "handleDaemonFrame writes build resolve error frame for malformed header with request id" {
    const allocator = std.testing.allocator;
    var reader = TestReader{};
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try handleDaemonFrame(
        allocator,
        std.testing.io,
        null,
        &reader,
        &out.writer,
        "@@ZBR_REQ_BEGIN 9 extra",
    );

    try std.testing.expectEqualStrings(
        "@@ZBR_RES_BEGIN 9\n@@ZBR_RES_ERR 9 InvalidBuildResolveDaemonHeader\n@@ZBR_RES_END 9\n",
        out.written(),
    );
}
