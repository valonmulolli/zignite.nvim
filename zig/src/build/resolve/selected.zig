const std = @import("std");
const command = @import("command.zig");
const detected = @import("detected.zig");
const pathing = @import("../../pathing.zig");
const runtime_materialize = @import("../../runtime/resolve/materialize.zig");
const types = @import("types.zig");

pub const ResolvedCommandExecution = struct {
    filetype: []u8,
    cwd: []u8,
    command_name: []u8,
    exec_command: []u8,
    exec_argv: std.ArrayList([]u8),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.filetype);
        allocator.free(self.cwd);
        allocator.free(self.command_name);
        allocator.free(self.exec_command);
        for (self.exec_argv.items) |arg| allocator.free(arg);
        self.exec_argv.deinit(allocator);
    }
};

pub fn resolveCommandExecution(
    allocator: std.mem.Allocator,
    options: types.Options,
) !ResolvedCommandExecution {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return resolveCommandExecutionWithIO(threaded.io(), allocator, options);
}

pub fn resolveCommandExecutionWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: types.Options,
) !ResolvedCommandExecution {
    var parsed_output = try detected.resolveOutputWithIO(io, allocator, options);
    defer parsed_output.deinit(allocator);

    const resolved_filetype = parsed_output.filetype orelse options.filetype;
    const command_name = options.command_name orelse return error.MissingBuildResolveCommandName;
    const command_template = detected.findCommand(parsed_output.commands.items, command_name) orelse return error.UnknownBuildResolveCommand;
    const resolved_command = try command.resolveCommandTemplate(
        allocator,
        resolved_filetype,
        command_name,
        command_template,
        options.command_args,
    );
    defer allocator.free(resolved_command);

    const path_resolved = try runtime_materialize.substituteVariablesShell(
        allocator,
        resolved_command,
        options.path,
        null,
    );
    errdefer allocator.free(path_resolved);

    if (command.isReservedArgvCommand(path_resolved)) {
        return error.ReservedBuildResolveArgvCommand;
    }

    const cwd = parsed_output.root orelse pathing.dirOrDot(options.path);
    var argv = try runtime_materialize.tokenizeCommand(allocator, path_resolved);
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    const owned_filetype = try allocator.dupe(u8, resolved_filetype);
    errdefer allocator.free(owned_filetype);

    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);

    const owned_command_name = try allocator.dupe(u8, command_name);
    errdefer allocator.free(owned_command_name);

    return .{
        .filetype = owned_filetype,
        .cwd = owned_cwd,
        .command_name = owned_command_name,
        .exec_command = path_resolved,
        .exec_argv = argv,
    };
}

test "resolveCommandExecution materializes selected command" {
    const allocator = std.testing.allocator;
    defer @import("../../config/store.zig").reset();
    try @import("../../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"zig":{"fetch":"zig fetch $zignite_args"}},"detect":{},"revision":41}
    , 41);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const filepath = try std.fs.path.join(allocator, &.{ root, "build.zig" });
    defer allocator.free(filepath);

    var resolved = try resolveCommandExecution(allocator, .{
        .path = filepath,
        .filetype = "zig",
        .command_name = "fetch",
        .command_args = "https://github.com/owner/repo",
        .project_root = root,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("zig", resolved.filetype);
    try std.testing.expectEqualStrings(root, resolved.cwd);
    try std.testing.expectEqualStrings("fetch", resolved.command_name);
    try std.testing.expectEqualStrings("zig fetch --save git+https://github.com/owner/repo", resolved.exec_command);
    try std.testing.expectEqualStrings("zig", resolved.exec_argv.items[0]);
    try std.testing.expectEqualStrings("fetch", resolved.exec_argv.items[1]);
}

test "resolveCommandExecution uses dot cwd for bare relative paths without detected root" {
    const allocator = std.testing.allocator;
    defer @import("../../config/store.zig").reset();
    try @import("../../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"custom":{"build":"echo build"}},"detect":{},"revision":42}
    , 42);

    var resolved = try resolveCommandExecution(allocator, .{
        .path = "main.txt",
        .filetype = "custom",
        .command_name = "build",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(".", resolved.cwd);
    try std.testing.expectEqualStrings("echo build", resolved.exec_command);
}

test "resolveCommandExecution substitutes file path variables" {
    const allocator = std.testing.allocator;
    defer @import("../../config/store.zig").reset();
    try @import("../../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"go":{"preview":"glow $file"}},"detect":{},"revision":50}
    , 50);

    var resolved = try resolveCommandExecution(allocator, .{
        .path = "/home/user/readme.md",
        .filetype = "go",
        .command_name = "preview",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("glow '/home/user/readme.md'", resolved.exec_command);
    try std.testing.expectEqualStrings("glow", resolved.exec_argv.items[0]);
    try std.testing.expectEqualStrings("/home/user/readme.md", resolved.exec_argv.items[1]);
}

test "resolveCommandExecution substitutes file path in compile command" {
    const allocator = std.testing.allocator;
    defer @import("../../config/store.zig").reset();
    try @import("../../config/store.zig").setSyncedConfigJson(
        \\{"build_commands":{"go":{"compile":"go run $file"}},"detect":{},"revision":51}
    , 51);

    var resolved = try resolveCommandExecution(allocator, .{
        .path = "/project/main.go",
        .filetype = "go",
        .command_name = "compile",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("go run '/project/main.go'", resolved.exec_command);
    try std.testing.expectEqualStrings("go", resolved.exec_argv.items[0]);
    try std.testing.expectEqualStrings("run", resolved.exec_argv.items[1]);
    try std.testing.expectEqualStrings("/project/main.go", resolved.exec_argv.items[2]);
}
