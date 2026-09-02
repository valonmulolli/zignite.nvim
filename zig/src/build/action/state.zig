const std = @import("std");
const state_allocator = std.heap.page_allocator;

const Entry = struct {
    filetype: []u8,
    command_name: []u8,
};

var last_commands: std.ArrayList(Entry) = .empty;
var state_mutex: std.Io.Mutex = .init;
var loaded_from_disk = false;

pub fn getLastCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    filetype: []const u8,
) !?[]u8 {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    try ensureLoadedLocked(io, allocator, environ_map);

    for (last_commands.items) |entry| {
        if (std.mem.eql(u8, entry.filetype, filetype)) return try allocator.dupe(u8, entry.command_name);
    }
    return null;
}

pub fn setLastCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    filetype: []const u8,
    command_name: []const u8,
) !void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    try ensureLoadedLocked(io, allocator, environ_map);

    for (last_commands.items) |*entry| {
        if (!std.mem.eql(u8, entry.filetype, filetype)) continue;
        const owned_command_name = try state_allocator.dupe(u8, command_name);
        const previous_command_name = entry.command_name;
        entry.command_name = owned_command_name;
        persistLocked(io, allocator, environ_map) catch |err| {
            entry.command_name = previous_command_name;
            state_allocator.free(owned_command_name);
            return err;
        };
        state_allocator.free(previous_command_name);
        return;
    }

    const owned_filetype = try state_allocator.dupe(u8, filetype);
    const owned_command_name = state_allocator.dupe(u8, command_name) catch |err| {
        state_allocator.free(owned_filetype);
        return err;
    };
    last_commands.append(state_allocator, .{
        .filetype = owned_filetype,
        .command_name = owned_command_name,
    }) catch |err| {
        state_allocator.free(owned_filetype);
        state_allocator.free(owned_command_name);
        return err;
    };
    persistLocked(io, allocator, environ_map) catch |err| {
        const inserted = last_commands.pop().?;
        state_allocator.free(inserted.filetype);
        state_allocator.free(inserted.command_name);
        return err;
    };
}

pub fn clearLastCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    filetype: []const u8,
) !void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    try ensureLoadedLocked(io, allocator, environ_map);

    var index: usize = 0;
    while (index < last_commands.items.len) : (index += 1) {
        const entry = last_commands.items[index];
        if (!std.mem.eql(u8, entry.filetype, filetype)) continue;

        const last_index = last_commands.items.len - 1;
        const moved = last_commands.items[last_index];
        if (index != last_index) last_commands.items[index] = moved;
        last_commands.items.len = last_index;
        persistLocked(io, allocator, environ_map) catch |err| {
            last_commands.items.len = last_index + 1;
            if (index != last_index) {
                last_commands.items[last_index] = moved;
                last_commands.items[index] = entry;
            } else {
                last_commands.items[index] = entry;
            }
            return err;
        };
        state_allocator.free(entry.filetype);
        state_allocator.free(entry.command_name);
        return;
    }
}

pub fn resetForTests() void {
    const io = std.testing.io;
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    clearEntriesLocked();
    loaded_from_disk = false;
    deleteStateFileLocked(io, state_allocator) catch {};
}

fn ensureLoadedLocked(io: std.Io, allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) !void {
    if (loaded_from_disk) return;

    const state_path = try stateFilePathAlloc(allocator, environ_map);
    defer allocator.free(state_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            loaded_from_disk = true;
            return;
        },
        else => return err,
    };
    defer allocator.free(contents);

    const initial_len = last_commands.items.len;
    errdefer {
        while (last_commands.items.len > initial_len) {
            const entry = last_commands.pop().?;
            state_allocator.free(entry.filetype);
            state_allocator.free(entry.command_name);
        }
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const tab_index = std.mem.findScalar(u8, trimmed, '\t') orelse continue;
        const filetype = trimmed[0..tab_index];
        const command_name = trimmed[tab_index + 1 ..];
        if (filetype.len == 0 or command_name.len == 0) continue;

        const owned_filetype = try state_allocator.dupe(u8, filetype);
        errdefer state_allocator.free(owned_filetype);
        const owned_command_name = try state_allocator.dupe(u8, command_name);
        errdefer state_allocator.free(owned_command_name);
        try last_commands.append(state_allocator, .{
            .filetype = owned_filetype,
            .command_name = owned_command_name,
        });
    }
    loaded_from_disk = true;
}

fn persistLocked(io: std.Io, allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) !void {
    const state_root = try stateRootAlloc(allocator, environ_map);
    defer allocator.free(state_root);
    try std.Io.Dir.cwd().createDirPath(io, state_root);

    const state_path = try stateFilePathAlloc(allocator, environ_map);
    defer allocator.free(state_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (last_commands.items) |entry| {
        try out.appendSlice(allocator, entry.filetype);
        try out.append(allocator, '\t');
        try out.appendSlice(allocator, entry.command_name);
        try out.append(allocator, '\n');
    }

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, state_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try file_writer.interface.writeAll(out.items);
    try file_writer.interface.flush();
    try atomic_file.replace(io);
}

fn stateRootAlloc(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "ZIGNITE_STATE_DIR")) |root| {
        return root;
    }
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "XDG_CACHE_HOME")) |xdg_cache_home| {
        defer allocator.free(xdg_cache_home);
        return std.fs.path.join(allocator, &.{ xdg_cache_home, "zignite", "state" });
    }
    if (try getEnvVarOwnedOrNull(allocator, environ_map, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "zignite", "state" });
    }
    return allocator.dupe(u8, "/tmp/zignite-state");
}

fn stateFilePathAlloc(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const root = try stateRootAlloc(allocator, environ_map);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "build-last-commands.tsv" });
}

fn getEnvVarOwnedOrNull(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    name: []const u8,
) !?[]u8 {
    const map = environ_map orelse return null;
    const value = map.get(name) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, value));
}

fn clearEntriesLocked() void {
    for (last_commands.items) |entry| {
        state_allocator.free(entry.filetype);
        state_allocator.free(entry.command_name);
    }
    last_commands.clearAndFree(state_allocator);
}

fn deleteStateFileLocked(io: std.Io, allocator: std.mem.Allocator) !void {
    const state_path = try stateFilePathAlloc(allocator, null);
    defer allocator.free(state_path);
    std.Io.Dir.cwd().deleteFile(io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "build action state stores and clears last command by filetype" {
    const allocator = std.testing.allocator;
    defer resetForTests();

    try setLastCommand(std.testing.io, allocator, null, "zig", "build");
    const build_command = (try getLastCommand(std.testing.io, allocator, null, "zig")).?;
    defer allocator.free(build_command);
    try std.testing.expectEqualStrings("build", build_command);

    try setLastCommand(std.testing.io, allocator, null, "zig", "run");
    const run_command = (try getLastCommand(std.testing.io, allocator, null, "zig")).?;
    defer allocator.free(run_command);
    try std.testing.expectEqualStrings("run", run_command);

    try clearLastCommand(std.testing.io, allocator, null, "zig");
    try std.testing.expect((try getLastCommand(std.testing.io, allocator, null, "zig")) == null);
}

test "build action state persists across reload" {
    const allocator = std.testing.allocator;
    defer resetForTests();

    try setLastCommand(std.testing.io, allocator, null, "python", "test");

    clearEntriesLocked();
    loaded_from_disk = false;

    const command = (try getLastCommand(std.testing.io, allocator, null, "python")).?;
    defer allocator.free(command);
    try std.testing.expectEqualStrings("test", command);
}

test "build action state rolls back when persistence fails" {
    const allocator = std.testing.allocator;
    defer resetForTests();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const blocked_root = try std.fs.path.join(allocator, &.{ root, "blocked" });
    defer allocator.free(blocked_root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory\n" });

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    try environ_map.put("ZIGNITE_STATE_DIR", root);

    try setLastCommand(std.testing.io, allocator, &environ_map, "zig", "build");
    try setLastCommand(std.testing.io, allocator, &environ_map, "python", "test");

    try environ_map.put("ZIGNITE_STATE_DIR", blocked_root);
    if (setLastCommand(std.testing.io, allocator, &environ_map, "zig", "run")) |_| {
        return error.TestExpectedError;
    } else |_| {}
    if (setLastCommand(std.testing.io, allocator, &environ_map, "go", "test")) |_| {
        return error.TestExpectedError;
    } else |_| {}
    if (clearLastCommand(std.testing.io, allocator, &environ_map, "python")) |_| {
        return error.TestExpectedError;
    } else |_| {}

    try environ_map.put("ZIGNITE_STATE_DIR", root);
    const zig_command = (try getLastCommand(std.testing.io, allocator, &environ_map, "zig")).?;
    defer allocator.free(zig_command);
    try std.testing.expectEqualStrings("build", zig_command);

    const python_command = (try getLastCommand(std.testing.io, allocator, &environ_map, "python")).?;
    defer allocator.free(python_command);
    try std.testing.expectEqualStrings("test", python_command);
    try std.testing.expect((try getLastCommand(std.testing.io, allocator, &environ_map, "go")) == null);
}
