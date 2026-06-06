const std = @import("std");
const common = @import("../common.zig");
const emit = @import("../emit.zig");
const project_io = @import("../io.zig");
const task_alias = @import("../emit/task_alias.zig");
const types = @import("../types.zig");
const make = @import("../../make/api.zig");
const zig_project = @import("../../zig/api.zig");

const Options = types.Options;

pub fn writeCargoAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const cargo_toml_path = (try project_io.findParentFileAllocWithIO(io, allocator, options.path, "Cargo.toml", 12)) orelse return true;
    defer allocator.free(cargo_toml_path);
    const cargo_contents = try common.readFileAllocWithIO(io, allocator, cargo_toml_path);
    defer allocator.free(cargo_contents);
    try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
        .kind = .cargo,
        .path = cargo_toml_path,
        .match_path = options.path,
    }, cargo_contents);
    return true;
}

pub fn writeGoAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const makefile_path = try project_io.findParentFileAnyAllocWithIO(io, allocator, options.path, make.marker_names, 10);
    defer if (makefile_path) |value| allocator.free(value);

    if (makefile_path) |project_path| {
        const project_root = std.fs.path.dirname(project_path) orelse project_path;
        try stdout.print("ROOT\t{s}\n", .{project_root});
        try stdout.print("SYSTEM\tmake\n", .{});

        const make_contents = try common.readFileAllocWithIO(io, allocator, project_path);
        defer allocator.free(make_contents);
        try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
            .kind = .make_auto,
            .path = project_path,
            .project_root = project_root,
        }, make_contents);
        return true;
    }

    const go_work_path = try project_io.findParentFileAllocWithIO(io, allocator, options.path, "go.work", 10);
    if (go_work_path) |project_path| {
        defer allocator.free(project_path);
        const project_root = std.fs.path.dirname(project_path) orelse project_path;
        const go_work_contents = try common.readFileAllocWithIO(io, allocator, project_path);
        defer allocator.free(go_work_contents);
        try stdout.print("ROOT\t{s}\n", .{project_root});
        try stdout.print("SYSTEM\tgo\n", .{});
        try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
            .kind = .go,
            .path = project_path,
            .match_path = options.path,
        }, go_work_contents);
        return true;
    }

    const go_mod_path = (try project_io.findParentFileAllocWithIO(io, allocator, options.path, "go.mod", 10)) orelse return true;
    defer allocator.free(go_mod_path);
    const project_root = std.fs.path.dirname(go_mod_path) orelse go_mod_path;
    const go_mod_contents = try common.readFileAllocWithIO(io, allocator, go_mod_path);
    defer allocator.free(go_mod_contents);
    try stdout.print("ROOT\t{s}\n", .{project_root});
    try stdout.print("SYSTEM\tgo\n", .{});
    try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
        .kind = .go,
        .path = go_mod_path,
        .match_path = options.path,
    }, go_mod_contents);
    return true;
}

pub fn writeZigAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const build_root = try zig_project.findBuildRootAllocWithIO(io, allocator, options.path, 12) orelse return true;
    defer allocator.free(build_root);

    try stdout.print("ROOT\t{s}\n", .{build_root});
    try stdout.print("SYSTEM\tzig\n", .{});
    try stdout.print("COMMAND\tbuild\tzig build\n", .{});

    const steps = zig_project.detectStepsWithIO(io, allocator, build_root) catch return true;
    defer zig_project.freeOwnedSteps(allocator, steps);
    const names = try stepNamesAlloc(allocator, steps);
    defer allocator.free(names);

    for (steps) |step| {
        if (std.mem.eql(u8, step.name, "build")) continue;
        if (std.mem.eql(u8, step.name, "install")) {
            try stdout.print("COMMAND\tinstall\tzig build install\n", .{});
            continue;
        }
        try stdout.print("COMMAND\t{s}\tzig build {s}\n", .{ step.name, step.name });
    }

    const canonical_aliases = [_][]const u8{
        "run",
        "live",
        "test",
        "release",
        "check",
        "fmt",
        "lint",
        "bench",
        "package",
        "dist",
        "bundle",
        "e2e",
        "smoke",
        "integration-test",
    };
    for (canonical_aliases) |alias| {
        if (containsName(names, alias)) continue;
        const source_name = task_alias.findSourceName(names, alias) orelse continue;
        try stdout.print("COMMAND\t{s}\tzig build {s}\n", .{ alias, source_name });
    }

    return true;
}

fn stepNamesAlloc(allocator: std.mem.Allocator, steps: []const zig_project.Step) ![][]u8 {
    var names = try allocator.alloc([]u8, steps.len);
    for (steps, 0..) |step, index| {
        names[index] = step.name;
    }
    return names;
}

fn containsName(names: []const []u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

pub fn writeCMakeAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const cmake_path = (try project_io.findParentFileAllocWithIO(io, allocator, options.path, "CMakeLists.txt", 12)) orelse return true;
    defer allocator.free(cmake_path);
    const cmake_contents = try common.readFileAllocWithIO(io, allocator, cmake_path);
    defer allocator.free(cmake_contents);
    try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
        .kind = .cmake,
        .path = cmake_path,
        .match_path = options.match_path orelse options.path,
    }, cmake_contents);
    return true;
}

pub fn writeMesonAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const meson_path = (try project_io.findParentFileAllocWithIO(io, allocator, options.path, "meson.build", 12)) orelse return true;
    defer allocator.free(meson_path);
    const meson_contents = try common.readFileAllocWithIO(io, allocator, meson_path);
    defer allocator.free(meson_contents);
    try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
        .kind = .meson,
        .path = meson_path,
        .match_path = options.match_path orelse options.path,
    }, meson_contents);
    return true;
}
