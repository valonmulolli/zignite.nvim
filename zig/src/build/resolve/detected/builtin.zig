const std = @import("std");
const build_types = @import("../../system/types.zig");
pub fn listBuildCommands(
    allocator: std.mem.Allocator,
    filetype: []const u8,
) ![]build_types.CommandEntry {
    const defs = builtinDefinitions(filetype);
    var commands = try std.ArrayList(build_types.CommandEntry).initCapacity(allocator, defs.len);
    errdefer {
        for (commands.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        commands.deinit(allocator);
    }

    for (defs) |entry| {
        const owned_name = try allocator.dupe(u8, entry.name);
        const owned_command = allocator.dupe(u8, entry.command) catch |err| {
            allocator.free(owned_name);
            return err;
        };
        commands.appendAssumeCapacity(.{
            .name = owned_name,
            .command = owned_command,
        });
    }
    return try commands.toOwnedSlice(allocator);
}

pub fn commandSystem(filetype: []const u8, name: []const u8) ?[]const u8 {
    for (builtinDefinitions(filetype)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.system;
    }
    return null;
}

const BuiltinCommand = struct {
    name: []const u8,
    command: []const u8,
    system: ?[]const u8 = null,
};

const BuiltinDefinitionSet = struct {
    filetype: []const u8,
    commands: []const BuiltinCommand,
};

fn builtinDefinitions(filetype: []const u8) []const BuiltinCommand {
    for (builtin_definition_sets) |set| {
        if (std.mem.eql(u8, set.filetype, filetype)) return set.commands;
    }
    return &empty_builtin_commands;
}

const empty_builtin_commands = [_]BuiltinCommand{};

const rust_builtin_commands = [_]BuiltinCommand{
    .{ .name = "build", .command = "cargo build" },
    .{ .name = "run", .command = "cargo run" },
    .{ .name = "test", .command = "cargo test" },
    .{ .name = "release", .command = "cargo build --release" },
    .{ .name = "release-run", .command = "cargo run --release" },
    .{ .name = "check", .command = "cargo check" },
    .{ .name = "clean", .command = "cargo clean" },
};

const zig_builtin_commands = [_]BuiltinCommand{
    .{ .name = "build", .command = "zig build" },
    .{ .name = "run", .command = "zig build run" },
    .{ .name = "test", .command = "zig build test" },
    .{ .name = "check", .command = "zig build check" },
    .{ .name = "release", .command = "zig build -Doptimize=ReleaseFast" },
    .{ .name = "release-run", .command = "zig build run -Doptimize=ReleaseFast" },
};

const odin_builtin_commands = [_]BuiltinCommand{
    .{ .name = "build", .command = "odin build ." },
    .{ .name = "run", .command = "odin run ." },
    .{ .name = "test", .command = "odin test ." },
    .{ .name = "release", .command = "odin build . -o:speed" },
    .{ .name = "check", .command = "odin check ." },
};

const fortran_builtin_commands = [_]BuiltinCommand{
    .{ .name = "build", .command = "gfortran *.f90 -o main" },
    .{ .name = "run", .command = "./main" },
    .{ .name = "clean", .command = "rm -f main" },
};

const lua_builtin_commands = [_]BuiltinCommand{
    .{ .name = "love", .command = "love ." },
};

const go_builtin_commands = [_]BuiltinCommand{
    .{ .name = "build", .command = "go build" },
    .{ .name = "run", .command = "go run ." },
    .{ .name = "test", .command = "go test ./..." },
    .{ .name = "clean", .command = "go clean" },
    .{ .name = "mod", .command = "go mod tidy" },
};

const python_builtin_commands = [_]BuiltinCommand{
    .{ .name = "run", .command = "python -m main" },
    .{ .name = "test", .command = "pytest" },
    .{ .name = "install", .command = "pip install -r requirements.txt" },
};

const c_family_cmake_builtin_commands = [_]BuiltinCommand{
    .{ .name = "build", .command = "make", .system = "make" },
    .{ .name = "cmake-config", .command = "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1", .system = "cmake" },
    .{ .name = "cmake-build", .command = "cmake --build build", .system = "cmake" },
    .{ .name = "cmake-clean", .command = "cmake --build build --target clean", .system = "cmake" },
    .{ .name = "cmake-debug", .command = "cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build", .system = "cmake" },
    .{ .name = "cmake-release", .command = "cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=1 && cmake --build build", .system = "cmake" },
};

const c_family_meson_builtin_commands = [_]BuiltinCommand{
    .{ .name = "meson-setup", .command = "meson setup build", .system = "meson" },
    .{ .name = "meson-build", .command = "meson compile -C build", .system = "meson" },
    .{ .name = "meson-clean", .command = "meson compile -C build --clean", .system = "meson" },
    .{ .name = "meson-test", .command = "meson test -C build", .system = "meson" },
};

const c_family_builtin_commands =
    c_family_cmake_builtin_commands ++
    c_family_meson_builtin_commands;

const cxx_builtin_commands =
    c_family_cmake_builtin_commands ++
    [_]BuiltinCommand{
        .{ .name = "cmake-test", .command = "ctest --test-dir build", .system = "cmake" },
    } ++
    c_family_meson_builtin_commands;

const builtin_definition_sets = [_]BuiltinDefinitionSet{
    .{ .filetype = "rust", .commands = &rust_builtin_commands },
    .{ .filetype = "zig", .commands = &zig_builtin_commands },
    .{ .filetype = "odin", .commands = &odin_builtin_commands },
    .{ .filetype = "fortran", .commands = &fortran_builtin_commands },
    .{ .filetype = "lua", .commands = &lua_builtin_commands },
    .{ .filetype = "go", .commands = &go_builtin_commands },
    .{ .filetype = "python", .commands = &python_builtin_commands },
    .{ .filetype = "c", .commands = &c_family_builtin_commands },
    .{ .filetype = "cpp", .commands = &cxx_builtin_commands },
};

test "listBuildCommands returns builtin go commands" {
    const allocator = std.testing.allocator;
    const commands = try listBuildCommands(allocator, "go");
    defer {
        for (commands) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        allocator.free(commands);
    }

    try std.testing.expectEqual(@as(usize, 5), commands.len);
    try std.testing.expectEqualStrings("build", commands[0].name);
    try std.testing.expectEqualStrings("go build", commands[0].command);
    try std.testing.expectEqualStrings("mod", commands[4].name);
}

test "commandSystem follows builtin command metadata" {
    try std.testing.expectEqualStrings("make", commandSystem("c", "build").?);
    try std.testing.expectEqualStrings("cmake", commandSystem("cpp", "cmake-test").?);
    try std.testing.expectEqualStrings("meson", commandSystem("c", "meson-build").?);
    try std.testing.expect(commandSystem("go", "build") == null);
}

test "cpp builtins extend c builtins with cmake test only" {
    try std.testing.expectEqual(c_family_builtin_commands.len + 1, cxx_builtin_commands.len);
    try std.testing.expectEqualStrings("cmake-test", cxx_builtin_commands[c_family_cmake_builtin_commands.len].name);
    try std.testing.expect(commandSystem("c", "cmake-test") == null);
}

test "listBuildCommands returns empty list for unknown filetype" {
    const allocator = std.testing.allocator;
    const commands = try listBuildCommands(allocator, "unknown");
    defer allocator.free(commands);
    try std.testing.expectEqual(@as(usize, 0), commands.len);
}

test "listBuildCommands returns rust commands with system field null" {
    const allocator = std.testing.allocator;
    const commands = try listBuildCommands(allocator, "rust");
    defer {
        for (commands) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        allocator.free(commands);
    }

    try std.testing.expectEqual(@as(usize, 7), commands.len);
    try std.testing.expectEqualStrings("cargo build", commands[0].command);
    try std.testing.expectEqualStrings("cargo clean", commands[6].command);
}

test "commandSystem returns null for unknown filetype or name" {
    try std.testing.expect(commandSystem("unknown", "build") == null);
    try std.testing.expect(commandSystem("go", "nonexistent") == null);
    try std.testing.expect(commandSystem("rust", "cmake-test") == null);
}

test "listBuildCommands returns builtin lua love command" {
    const allocator = std.testing.allocator;
    const commands = try listBuildCommands(allocator, "lua");
    defer {
        for (commands) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        allocator.free(commands);
    }

    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqualStrings("love", commands[0].name);
    try std.testing.expectEqualStrings("love .", commands[0].command);
}

test "listBuildCommands returns empty list for unknown filetypes that are close but not registered" {
    const allocator = std.testing.allocator;
    {
        const commands = try listBuildCommands(allocator, "mdown");
        defer allocator.free(commands);
        try std.testing.expectEqual(@as(usize, 0), commands.len);
    }
    {
        const commands = try listBuildCommands(allocator, "typ");
        defer allocator.free(commands);
        try std.testing.expectEqual(@as(usize, 0), commands.len);
    }
}
