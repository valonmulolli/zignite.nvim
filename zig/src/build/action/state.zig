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
) !?[]const u8 {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    ensureLoadedLocked(io, allocator, environ_map) catch |err| {
        std.log.warn("Failed to load build action state: {}", .{err});
        return null;
    };

    for (last_commands.items) |entry| {
        if (std.mem.eql(u8, entry.filetype, filetype)) return entry.command_name;
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
    ensureLoadedLocked(io, allocator, environ_map) catch |err| {
        std.log.warn("Failed to load build action state for write: {}", .{err});
        return;
    };

    for (last_commands.items) |*entry| {
        if (!std.mem.eql(u8, entry.filetype, filetype)) continue;
        const owned_command_name = try state_allocator.dupe(u8, command_name);
        state_allocator.free(entry.command_name);
        entry.command_name = owned_command_name;
        persistLocked(io, allocator, environ_map) catch |err| {
            std.log.warn("Failed to persist build action state: {}", .{err});
        };
        return;
    }

    const owned_filetype = try state_allocator.dupe(u8, filetype);
    errdefer state_allocator.free(owned_filetype);
    const owned_command_name = try state_allocator.dupe(u8, command_name);
    errdefer state_allocator.free(owned_command_name);
    try last_commands.append(state_allocator, .{
        .filetype = owned_filetype,
        .command_name = owned_command_name,
    });
    persistLocked(io, allocator, environ_map) catch |err| {
        std.log.warn("Failed to persist build action state: {}", .{err});
    };
}

pub fn clearLastCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    filetype: []const u8,
) void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    ensureLoadedLocked(io, allocator, environ_map) catch return;

    var index: usize = 0;
    while (index < last_commands.items.len) : (index += 1) {
        const entry = last_commands.items[index];
        if (!std.mem.eql(u8, entry.filetype, filetype)) continue;

        state_allocator.free(entry.filetype);
        state_allocator.free(entry.command_name);
        _ = last_commands.swapRemove(index);
        persistLocked(io, allocator, environ_map) catch {};
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
    loaded_from_disk = true;

    const state_path = try stateFilePathAlloc(allocator, environ_map);
    defer allocator.free(state_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(contents);

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

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = state_path,
        .data = out.items,
    });
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
    try std.testing.expectEqualStrings("build", (try getLastCommand(std.testing.io, allocator, null, "zig")).?);

    try setLastCommand(std.testing.io, allocator, null, "zig", "run");
    try std.testing.expectEqualStrings("run", (try getLastCommand(std.testing.io, allocator, null, "zig")).?);

    clearLastCommand(std.testing.io, allocator, null, "zig");
    try std.testing.expect((try getLastCommand(std.testing.io, allocator, null, "zig")) == null);
}

test "build action state persists across reload" {
    const allocator = std.testing.allocator;
    defer resetForTests();

    try setLastCommand(std.testing.io, allocator, null, "python", "test");

    clearEntriesLocked();
    loaded_from_disk = false;

    try std.testing.expectEqualStrings("test", (try getLastCommand(std.testing.io, allocator, null, "python")).?);
}
