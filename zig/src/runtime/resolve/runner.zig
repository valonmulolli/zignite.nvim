const std = @import("std");
const build_resolve = @import("../../build/resolve.zig");
const build_detected = @import("../../build/resolve/detected.zig");
const config_view = @import("../../config/view.zig");
const builtin = @import("builtin.zig");
const materialize = @import("materialize.zig");
const source = @import("../source.zig");
const types = @import("types.zig");
const zig_classifier = @import("zig_classifier.zig");

const project_runner_preferred_names = [_][]const u8{ "run", "live", "dev", "watch", "serve", "start", "preview", "build" };

pub fn resolveRunner(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    options: types.Options,
) !types.ResolvedRunner {
    var prepared = try source.prepareSource(io, allocator, environ_map, .{
        .source_path = options.path,
        .filetype = options.filetype,
        .buffer_id = options.buffer_id,
        .input_kind = options.input_kind,
        .selection_text = options.selection_text,
    });
    defer prepared.deinit(allocator);

    const execution_path = prepared.execution_path;
    const context_path = options.context_path orelse options.path;
    const has_project_context = context_path.len > 0;

    if (!has_project_context) {
        const resolved_filetype = options.filetype;
        if (try collectFiletypeRunner(allocator, resolved_filetype)) |configured| {
            var resolved = configured;
            errdefer resolved.deinit(allocator);
            resolved.filetype = try allocator.dupe(u8, resolved_filetype);
            try materialize.materializeRunner(allocator, &resolved, execution_path);
            try attachExecutionPath(allocator, &resolved, execution_path);
            return resolved;
        }

        return try minimalRunner(allocator, resolved_filetype, execution_path);
    }

    // Avoid triggering Zig build-step discovery during RunFile when the source
    // already proves it must run via the project build graph.
    if (std.mem.eql(u8, options.filetype, "zig")) {
        if (try zig_classifier.shouldPreferProjectRunnerWithIO(io, allocator, options.path, context_path, options.project_root)) {
            if (try buildZigProjectRunner(io, allocator, context_path, options.project_root)) |resolved_raw| {
                var resolved = resolved_raw;
                errdefer resolved.deinit(allocator);
                try materialize.materializeRunner(allocator, &resolved, execution_path);
                try attachExecutionPath(allocator, &resolved, execution_path);
                return resolved;
            }
        }

        if (try collectFiletypeRunner(allocator, "zig")) |configured| {
            var resolved = configured;
            errdefer resolved.deinit(allocator);
            resolved.filetype = try allocator.dupe(u8, "zig");
            try materialize.materializeRunner(allocator, &resolved, execution_path);
            try attachExecutionPath(allocator, &resolved, execution_path);
            return resolved;
        }
    }

    if (std.mem.eql(u8, options.filetype, "go")) {
        if (try collectFiletypeRunner(allocator, "go")) |configured| {
            var resolved = configured;
            errdefer resolved.deinit(allocator);
            resolved.filetype = try allocator.dupe(u8, "go");
            try materialize.materializeRunner(allocator, &resolved, execution_path);
            try attachExecutionPath(allocator, &resolved, execution_path);
            return resolved;
        }
    }

    var build_output = try build_resolve.resolveDetectedOutputWithIO(io, allocator, .{
        .path = context_path,
        .filetype = options.filetype,
        .project_root = options.project_root,
    });
    defer build_output.deinit(allocator);
    const resolved_filetype = build_output.filetype orelse options.filetype;

    if (try collectFiletypeRunner(allocator, resolved_filetype)) |configured| {
        var resolved = configured;
        errdefer resolved.deinit(allocator);
        try applySmartRunnerDefaults(allocator, resolved_filetype, &build_output, &resolved);
        resolved.filetype = try allocator.dupe(u8, resolved_filetype);
        try materialize.materializeRunner(allocator, &resolved, execution_path);
        try attachExecutionPath(allocator, &resolved, execution_path);
        return resolved;
    }

    if (try buildProjectRunner(allocator, resolved_filetype, &build_output)) |resolved_raw| {
        var resolved = resolved_raw;
        errdefer resolved.deinit(allocator);
        try materialize.materializeRunner(allocator, &resolved, execution_path);
        try attachExecutionPath(allocator, &resolved, execution_path);
        return resolved;
    }

    return try minimalRunner(allocator, resolved_filetype, execution_path);
}

fn minimalRunner(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    execution_path: []const u8,
) !types.ResolvedRunner {
    var resolved = types.ResolvedRunner{
        .filetype = try allocator.dupe(u8, filetype),
    };
    errdefer resolved.deinit(allocator);

    resolved.execution_path = try allocator.dupe(u8, execution_path);
    resolved.name = try allocator.dupe(u8, filetype);
    return resolved;
}

fn attachExecutionPath(
    allocator: std.mem.Allocator,
    resolved: *types.ResolvedRunner,
    execution_path: []const u8,
) !void {
    if (resolved.execution_path) |existing| {
        allocator.free(existing);
        resolved.execution_path = null;
    }
    resolved.execution_path = try allocator.dupe(u8, execution_path);
}

fn collectFiletypeRunner(allocator: std.mem.Allocator, filetype: []const u8) !?types.ResolvedRunner {
    const configured = (try config_view.loadRunnerConfig(allocator, filetype)) orelse
        (try builtin.loadRunnerConfig(allocator, filetype)) orelse return null;
    return .{
        .command = configured.command,
        .cleanup_command = configured.cleanup_command,
        .cwd = configured.cwd,
    };
}

fn applySmartRunnerDefaults(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    build_output: *const build_resolve.ResolvedOutput,
    resolved: *types.ResolvedRunner,
) !void {
    const command = resolved.command orelse return;

    if (std.mem.eql(u8, filetype, "python") and std.mem.eql(u8, command, "python3 -u $file")) {
        if (build_detected.findCommand(build_output.commands.items, "run")) |project_run| {
            if (std.mem.startsWith(u8, project_run, "uv run ") or std.mem.startsWith(u8, project_run, "conda run ")) {
                const owned_project_run = try allocator.dupe(u8, project_run);
                allocator.free(command);
                resolved.command = owned_project_run;
            }
        }
        return;
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
    };
    errdefer resolved.deinit(allocator);

    resolved.command = try allocator.dupe(u8, command);
    resolved.name = try formatProjectName(allocator, filetype);
    if (build_output.root) |root| {
        resolved.cwd = try allocator.dupe(u8, root);
    }
    return resolved;
}

fn buildZigProjectRunner(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    project_root: ?[]const u8,
) !?types.ResolvedRunner {
    const root = try zig_classifier.findBuildRootAllocWithIO(io, allocator, path, project_root, 12) orelse return null;
    defer allocator.free(root);

    var resolved = types.ResolvedRunner{
        .source = "project",
        .filetype = try allocator.dupe(u8, "zig"),
    };
    errdefer resolved.deinit(allocator);

    resolved.command = try allocator.dupe(u8, "zig build run");
    resolved.cwd = try allocator.dupe(u8, root);
    resolved.name = try allocator.dupe(u8, "Zig Project");
    return resolved;
}

fn findPreferredProjectCommand(build_output: *const build_resolve.ResolvedOutput) ?[]const u8 {
    const name = build_detected.findPreferredCommandName(
        build_output.preferred.items,
        build_output.commands.items,
        &project_runner_preferred_names,
    ) orelse return null;
    if (build_detected.findCommand(build_output.commands.items, name)) |command| return command;
    if (build_detected.findCommand(build_output.preferred.items, name)) |command| return command;
    return null;
}

fn formatProjectName(allocator: std.mem.Allocator, filetype: []const u8) ![]u8 {
    var text = try allocator.dupe(u8, filetype);
    defer allocator.free(text);
    if (text.len > 0 and std.ascii.isLower(text[0])) {
        text[0] = std.ascii.toUpper(text[0]);
    }
    return std.fmt.allocPrint(allocator, "{s} Project", .{text});
}

test "formatProjectName capitalizes the filetype without leaking temp storage" {
    const allocator = std.testing.allocator;
    const name = try formatProjectName(allocator, "python");
    defer allocator.free(name);

    try std.testing.expectEqualStrings("Python Project", name);
}
