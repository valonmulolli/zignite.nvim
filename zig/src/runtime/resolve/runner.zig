const std = @import("std");
const build_resolve = @import("../../build/resolve.zig");
const build_types = @import("../../build/system/types.zig");
const config = @import("../../config.zig");
const materialize = @import("materialize.zig");
const types = @import("types.zig");

pub fn resolveRunner(allocator: std.mem.Allocator, options: types.Options) !types.ResolvedRunner {
    const context_path = options.context_path orelse options.path;
    var build_output = try build_resolve.resolveDetectedOutput(allocator, .{
        .path = context_path,
        .filetype = options.filetype,
        .project_root = options.project_root,
    });
    defer build_output.deinit(allocator);
    const resolved_filetype = build_output.filetype orelse options.filetype;

    if (std.mem.eql(u8, resolved_filetype, "zig")) {
        if (try buildZigProjectRunner(allocator, context_path, options.project_root)) |resolved| {
            return try materialize.materializeRunner(allocator, resolved, options.path);
        }
        if (try buildProjectRunner(allocator, resolved_filetype, &build_output)) |resolved| {
            return try materialize.materializeRunner(allocator, resolved, options.path);
        }
    }

    if (try collectConfiguredRunner(allocator, resolved_filetype)) |configured| {
        var resolved = configured;
        errdefer resolved.deinit(allocator);
        try applySmartRunnerDefaults(allocator, resolved_filetype, &build_output, &resolved);
        resolved.filetype = try allocator.dupe(u8, resolved_filetype);
        return try materialize.materializeRunner(allocator, resolved, options.path);
    }

    if (try buildProjectRunner(allocator, resolved_filetype, &build_output)) |resolved| {
        return try materialize.materializeRunner(allocator, resolved, options.path);
    }

    return .{
        .filetype = try allocator.dupe(u8, resolved_filetype),
        .name = try allocator.dupe(u8, resolved_filetype),
    };
}

fn collectConfiguredRunner(allocator: std.mem.Allocator, filetype: []const u8) !?types.ResolvedRunner {
    const raw = config.getSyncedConfigJson() orelse return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const runners = parsed.value.object.get("runners") orelse return null;
    if (runners != .object) return null;
    const runner_value = runners.object.get(filetype) orelse return null;

    return try parseRunnerValue(allocator, runner_value);
}

fn parseRunnerValue(allocator: std.mem.Allocator, value: std.json.Value) !?types.ResolvedRunner {
    switch (value) {
        .string => |command| {
            if (command.len == 0) return null;
            return .{ .command = try allocator.dupe(u8, command) };
        },
        .array => {
            const joined = try joinCommandArray(allocator, value.array.items);
            if (joined == null) return null;
            return .{ .command = joined };
        },
        .object => {
            const cmd_value = value.object.get("cmd") orelse return null;
            const command = try parseRunnerCommand(allocator, cmd_value) orelse return null;
            var resolved = types.ResolvedRunner{ .command = command };
            errdefer resolved.deinit(allocator);

            if (value.object.get("cleanup_command")) |cleanup| {
                if (cleanup == .string and cleanup.string.len > 0) {
                    resolved.cleanup_command = try allocator.dupe(u8, cleanup.string);
                }
            }
            if (value.object.get("cwd")) |cwd| {
                if (cwd == .string and cwd.string.len > 0) {
                    resolved.cwd = try allocator.dupe(u8, cwd.string);
                }
            }
            return resolved;
        },
        else => return null,
    }
}

fn parseRunnerCommand(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .string => |command| if (command.len == 0) null else try allocator.dupe(u8, command),
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
    return joined.toOwnedSlice(allocator);
}

fn applySmartRunnerDefaults(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    build_output: *const build_resolve.ResolvedOutput,
    resolved: *types.ResolvedRunner,
) !void {
    const command = resolved.command orelse return;

    if (std.mem.eql(u8, filetype, "python") and std.mem.eql(u8, command, "python3 -u $file")) {
        if (findCommand(build_output.commands.items, "run")) |project_run| {
            if (std.mem.startsWith(u8, project_run, "uv run ")) {
                allocator.free(command);
                resolved.command = try allocator.dupe(u8, project_run);
            }
        }
        return;
    }

    if (std.mem.eql(u8, filetype, "go") and std.mem.eql(u8, command, "go run $file")) {
        if (findCommand(build_output.commands.items, "run")) |project_run| {
            allocator.free(command);
            resolved.command = try allocator.dupe(u8, project_run);
            if (resolved.cwd == null) {
                resolved.cwd = try allocator.dupe(u8, "$dir");
            }
        }
    }
}

fn buildProjectRunner(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    build_output: *const build_resolve.ResolvedOutput,
) !?types.ResolvedRunner {
    const command = findPreferredProjectCommand(build_output) orelse return null;

    var resolved = types.ResolvedRunner{
        .source = "project",
        .filetype = try allocator.dupe(u8, filetype),
        .command = try allocator.dupe(u8, command),
        .name = try formatProjectName(allocator, filetype),
    };
    errdefer resolved.deinit(allocator);

    if (build_output.root) |root| {
        resolved.cwd = try allocator.dupe(u8, root);
    }
    return resolved;
}

fn buildZigProjectRunner(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !?types.ResolvedRunner {
    const root = try findMarkerRootAlloc(allocator, path, project_root, "build.zig", 12) orelse return null;
    defer allocator.free(root);

    return .{
        .source = "project",
        .filetype = try allocator.dupe(u8, "zig"),
        .command = try allocator.dupe(u8, "zig build run"),
        .cwd = try allocator.dupe(u8, root),
        .name = try allocator.dupe(u8, "Zig Project"),
    };
}

fn findPreferredProjectCommand(build_output: *const build_resolve.ResolvedOutput) ?[]const u8 {
    const names = [_][]const u8{ "run", "live", "dev", "watch", "serve", "start", "preview", "build" };
    for (names) |name| {
        if (findCommand(build_output.preferred.items, name)) |command| return command;
    }
    for (names) |name| {
        if (findCommand(build_output.commands.items, name)) |command| return command;
    }
    return null;
}

fn findCommand(commands: []const build_types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

fn formatProjectName(allocator: std.mem.Allocator, filetype: []const u8) ![]u8 {
    var text = try allocator.dupe(u8, filetype);
    errdefer allocator.free(text);
    if (text.len > 0 and std.ascii.isLower(text[0])) {
        text[0] = std.ascii.toUpper(text[0]);
    }
    return std.fmt.allocPrint(allocator, "{s} Project", .{text});
}

fn findMarkerRootAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
    marker: []const u8,
    max_up: usize,
) !?[]u8 {
    if (project_root) |root| {
        if (root.len > 0 and pathHasFile(root, marker)) {
            return allocator.dupe(u8, root);
        }
    }

    var current = try allocator.dupe(u8, std.fs.path.dirname(path) orelse path);
    defer allocator.free(current);

    var steps: usize = 0;
    while (steps < max_up) : (steps += 1) {
        if (pathHasFile(current, marker)) {
            return allocator.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return null;
}

fn pathHasFile(root: []const u8, name: []const u8) bool {
    const full_path = std.fs.path.join(std.heap.page_allocator, &.{ root, name }) catch return false;
    defer std.heap.page_allocator.free(full_path);

    if (std.fs.path.isAbsolute(full_path)) {
        std.fs.accessAbsolute(full_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}
