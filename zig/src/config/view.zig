const std = @import("std");
const filetype_policy = @import("../filetype_policy.zig");
const store = @import("store.zig");

pub const BuildCommand = struct {
    name: []const u8,
    command: []const u8,
};

pub const RunnerConfig = struct {
    command: ?[]u8 = null,
    cleanup_command: ?[]u8 = null,
    cwd: ?[]u8 = null,

    pub fn deinit(self: *RunnerConfig, allocator: std.mem.Allocator) void {
        if (self.command) |command| allocator.free(command);
        if (self.cleanup_command) |cleanup| allocator.free(cleanup);
        if (self.cwd) |cwd| allocator.free(cwd);
    }
};

const ParsedCache = struct {
    generation: ?u64 = null,
    arena: ?std.heap.ArenaAllocator = null,
    parsed: ?std.json.Parsed(std.json.Value) = null,
};

var cache: ParsedCache = .{};

fn clearCache() void {
    if (cache.arena) |*arena| {
        arena.deinit();
    }
    cache = .{};
}

fn rootObject() ?std.json.ObjectMap {
    const generation = store.getSyncedGeneration();
    if (cache.generation) |cached| {
        if (cached != generation) clearCache();
    }

    if (cache.parsed == null) {
        const raw = store.getSyncedConfigJson() orelse {
            return null;
        };

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{}) catch {
            arena.deinit();
            return null;
        };

        if (parsed.value != .object) {
            arena.deinit();
            return null;
        }

        cache.arena = arena;
        cache.parsed = parsed;
        cache.generation = generation;
    }

    return cache.parsed.?.value.object;
}

fn objectField(root: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = root.get(key) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn filetypeObjectField(root: std.json.ObjectMap, section_key: []const u8, filetype: []const u8) ?std.json.ObjectMap {
    const section = objectField(root, section_key) orelse return null;
    const value = section.get(filetype) orelse return null;
    if (value != .object) return null;
    return value.object;
}

pub fn hasConfiguredEntryForFiletype(filetype: []const u8) bool {
    const root = rootObject() orelse return false;
    if (objectField(root, "runners")) |runners| {
        if (runners.get(filetype) != null) return true;
    }
    if (objectField(root, "build_commands")) |commands| {
        if (commands.get(filetype) != null) return true;
    }
    return false;
}

pub fn isDetectEnabled(filetype: []const u8) bool {
    const key = filetype_policy.detectKeyForFiletype(filetype) orelse return true;
    const root = rootObject() orelse return true;
    const detect = objectField(root, "detect") orelse return true;
    const enabled = detect.get(key) orelse return true;
    if (enabled != .bool) return true;
    return enabled.bool;
}

pub fn executionTimeoutMs() ?u64 {
    const root = rootObject() orelse return null;
    const timeout = root.get("timeout") orelse return null;
    return switch (timeout) {
        .integer => |value| if (value > 0) @as(u64, @intCast(value)) else null,
        .float => |value| if (std.math.isFinite(value) and value > 0) @as(u64, @trunc(value)) else null,
        else => null,
    };
}

pub fn listBuildCommands(
    allocator: std.mem.Allocator,
    filetype: []const u8,
) ![]BuildCommand {
    const root = rootObject() orelse return allocator.alloc(BuildCommand, 0);
    const filetype_commands = filetypeObjectField(root, "build_commands", filetype) orelse return allocator.alloc(BuildCommand, 0);

    var commands = try std.ArrayList(BuildCommand).initCapacity(allocator, filetype_commands.count());
    errdefer {
        for (commands.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.command);
        }
        commands.deinit(allocator);
    }

    var it = filetype_commands.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;

        const owned_name = try allocator.dupe(u8, entry.key_ptr.*);
        const owned_command = allocator.dupe(u8, entry.value_ptr.string) catch |err| {
            allocator.free(owned_name);
            return err;
        };
        commands.append(allocator, .{
            .name = owned_name,
            .command = owned_command,
        }) catch |err| {
            allocator.free(owned_name);
            allocator.free(owned_command);
            return err;
        };
    }

    return commands.toOwnedSlice(allocator);
}

pub fn freeBuildCommands(allocator: std.mem.Allocator, commands: []BuildCommand) void {
    for (commands) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.command);
    }
    allocator.free(commands);
}

pub fn loadRunnerConfig(allocator: std.mem.Allocator, filetype: []const u8) !?RunnerConfig {
    const root = rootObject() orelse return null;
    const runners = objectField(root, "runners") orelse return null;
    const runner_value = runners.get(filetype) orelse return null;

    return switch (runner_value) {
        .string => |command| blk: {
            if (command.len == 0) break :blk null;
            break :blk RunnerConfig{ .command = try allocator.dupe(u8, command) };
        },
        .array => blk: {
            const joined = try joinCommandArray(allocator, runner_value.array.items);
            if (joined == null) break :blk null;
            break :blk RunnerConfig{ .command = joined };
        },
        .object => blk: {
            const cmd_value = runner_value.object.get("cmd") orelse break :blk null;
            const command = try parseRunnerCommand(allocator, cmd_value) orelse break :blk null;
            var resolved = RunnerConfig{ .command = command };
            errdefer resolved.deinit(allocator);

            if (runner_value.object.get("cleanup_command")) |cleanup| {
                if (cleanup == .string and cleanup.string.len > 0) {
                    resolved.cleanup_command = try allocator.dupe(u8, cleanup.string);
                }
            }
            if (runner_value.object.get("cwd")) |cwd| {
                if (cwd == .string and cwd.string.len > 0) {
                    resolved.cwd = try allocator.dupe(u8, cwd.string);
                }
            }
            break :blk resolved;
        },
        else => null,
    };
}

fn parseRunnerCommand(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .string => |command| if (command.len == 0) null else @as(?[]u8, try allocator.dupe(u8, command)),
        .array => try joinCommandArray(allocator, value.array.items),
        else => null,
    };
}

fn joinCommandArray(allocator: std.mem.Allocator, items: []const std.json.Value) !?[]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    var appended = false;
    for (items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (appended) try joined.appendSlice(allocator, " && ");
        try joined.appendSlice(allocator, item.string);
        appended = true;
    }

    if (!appended) return null;
    return @as(?[]u8, try joined.toOwnedSlice(allocator));
}

test "view caches and exposes configured entries" {
    defer store.reset();
    clearCache();

    try store.setSyncedConfigJson(
        \\{"runners":{"typescript":"bun $file"},"build_commands":{"zig":{"build":"zig build"}},"detect":{"js_package_scripts":false},"revision":3}
    , 3);

    try std.testing.expect(hasConfiguredEntryForFiletype("typescript"));
    try std.testing.expect(hasConfiguredEntryForFiletype("zig"));
    try std.testing.expect(!isDetectEnabled("typescript"));

    const commands = try listBuildCommands(std.testing.allocator, "zig");
    defer freeBuildCommands(std.testing.allocator, commands);
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqualStrings("build", commands[0].name);
    try std.testing.expectEqualStrings("zig build", commands[0].command);

    var runner = (try loadRunnerConfig(std.testing.allocator, "typescript")).?;
    defer runner.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bun $file", runner.command.?);
}

test "view invalidates on revision change" {
    defer store.reset();
    clearCache();

    try store.setSyncedConfigJson(
        \\{"runners":{"python":"python3 -u $file"},"build_commands":{},"detect":{},"revision":1}
    , 1);
    var runner = (try loadRunnerConfig(std.testing.allocator, "python")).?;
    defer runner.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("python3 -u $file", runner.command.?);

    try store.setSyncedConfigJson(
        \\{"runners":{"python":"uv run python $file"},"build_commands":{},"detect":{},"revision":2}
    , 2);
    var updated = (try loadRunnerConfig(std.testing.allocator, "python")).?;
    defer updated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("uv run python $file", updated.command.?);
}

test "view invalidates when synced json changes without revision change" {
    defer store.reset();
    clearCache();

    try store.setSyncedConfigJson(
        \\{"runners":{"python":"python3 -u $file"},"build_commands":{},"detect":{},"revision":9}
    , 9);
    var runner = (try loadRunnerConfig(std.testing.allocator, "python")).?;
    defer runner.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("python3 -u $file", runner.command.?);

    try store.setSyncedConfigJson(
        \\{"runners":{"python":"uv run python $file"},"build_commands":{},"detect":{},"revision":9}
    , 9);
    var updated = (try loadRunnerConfig(std.testing.allocator, "python")).?;
    defer updated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("uv run python $file", updated.command.?);
}

test "view exposes positive timeout values" {
    defer store.reset();
    clearCache();

    try store.setSyncedConfigJson(
        \\{"runners":{},"build_commands":{},"detect":{},"timeout":2500,"revision":4}
    , 4);
    try std.testing.expectEqual(@as(?u64, 2500), executionTimeoutMs());
}

test "listBuildCommands returns owned copies" {
    defer store.reset();
    clearCache();

    try store.setSyncedConfigJson(
        \\{"build_commands":{"zig":{"build":"zig build"}},"detect":{},"revision":10}
    , 10);

    const commands = try listBuildCommands(std.testing.allocator, "zig");
    defer freeBuildCommands(std.testing.allocator, commands);

    try std.testing.expectEqualStrings("build", commands[0].name);
    try std.testing.expectEqualStrings("zig build", commands[0].command);

    clearCache();
    store.reset();
    try std.testing.expectEqualStrings("build", commands[0].name);
    try std.testing.expectEqualStrings("zig build", commands[0].command);
}
