const std = @import("std");
const build_system = @import("../../../build/system.zig");
const cache = @import("../cache.zig");
const common = @import("../common.zig");
const direct = @import("direct.zig");
const emit = @import("../emit.zig");
const project_io = @import("../io.zig");
const signature = @import("signature.zig");
const types = @import("../types.zig");

const Options = types.Options;

pub fn writeSystemResult(stdout: anytype, result: build_system.Result) !void {
    if (result.root) |root| {
        try stdout.print("ROOT\t{s}\n", .{root});
    }
    if (result.system) |name| {
        try stdout.print("SYSTEM\t{s}\n", .{name});
    }
    if (result.build_ready) |ready| {
        try stdout.print("BUILD_READY\t{d}\n", .{if (ready) @as(u8, 1) else @as(u8, 0)});
    }
    for (result.commands) |entry| {
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
}

pub fn writeSystemQueryOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const query = options.query orelse return error.MissingSystemQuery;
    const result = try build_system.detectWithIO(io, allocator, query, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);
    try writeSystemResult(stdout, result);
    return true;
}

pub fn writeJVMAutoWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const result = try build_system.detectWithIO(io, allocator, .jvm_root, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);
    if (try signature.buildJVMAutoSignatureAllocWithIO(io, allocator, result)) |key| {
        defer allocator.free(key);
        if (try cache.getAutoOutput(options, key)) |cached_output| {
            try stdout.writeAll(cached_output);
            return true;
        }

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try writeJVMAutoOutputWithIO(io, &out.writer, allocator, result);
        const output = try out.toOwnedSlice();
        defer allocator.free(output);

        try cache.storeAutoOutput(options, key, output);
        try stdout.writeAll(output);
        return true;
    }

    try writeJVMAutoOutputWithIO(io, stdout, allocator, result);
    return true;
}

pub fn writeCFamilyAutoWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const result = try build_system.detectWithIO(io, allocator, .c_family, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);
    if (try signature.buildCFamilyAutoSignatureAllocWithIO(io, allocator, options, result)) |key| {
        defer allocator.free(key);
        if (try cache.getAutoOutput(options, key)) |cached_output| {
            try stdout.writeAll(cached_output);
            return true;
        }

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try writeCFamilyAutoOutputWithIO(io, &out.writer, allocator, options, result);
        const output = try out.toOwnedSlice();
        defer allocator.free(output);

        try cache.storeAutoOutput(options, key, output);
        try stdout.writeAll(output);
        return true;
    }

    try writeCFamilyAutoOutputWithIO(io, stdout, allocator, options, result);
    return true;
}

pub fn writePythonAutoWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const result = try build_system.detectWithIO(io, allocator, .python_root, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);
    if (try signature.buildPythonAutoSignatureAllocWithIO(io, allocator, result)) |key| {
        defer allocator.free(key);
        if (try cache.getAutoOutput(options, key)) |cached_output| {
            try stdout.writeAll(cached_output);
            return true;
        }

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try writePythonAutoOutputWithIO(io, &out.writer, allocator, options);
        const output = try out.toOwnedSlice();
        defer allocator.free(output);

        try cache.storeAutoOutput(options, key, output);
        try stdout.writeAll(output);
        return true;
    }

    try writePythonAutoOutputWithIO(io, stdout, allocator, options);
    return true;
}

pub fn writeBazelAutoWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !bool {
    const result = try build_system.detectWithIO(io, allocator, .bazel_root, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);
    if (try signature.buildBazelAutoSignatureAllocWithIO(io, allocator, options, result)) |key| {
        defer allocator.free(key);
        if (try cache.getAutoOutput(options, key)) |cached_output| {
            try stdout.writeAll(cached_output);
            return true;
        }

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        try writeBazelAutoOutputWithIO(io, &out.writer, allocator, options, result);
        const output = try out.toOwnedSlice();
        defer allocator.free(output);

        try cache.storeAutoOutput(options, key, output);
        try stdout.writeAll(output);
        return true;
    }

    try writeBazelAutoOutputWithIO(io, stdout, allocator, options, result);
    return true;
}

fn writeJVMAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, result: build_system.Result) !void {
    const root = result.root orelse return;
    const system = result.system orelse return;

    if (std.mem.eql(u8, system, "maven")) {
        const pom_path = try std.fs.path.join(allocator, &.{ root, "pom.xml" });
        defer allocator.free(pom_path);
        const pom_contents = try common.readFileAllocWithIO(io, allocator, pom_path);
        defer allocator.free(pom_contents);
        try emit.writeDirectOutputWithIO(io, stdout, allocator, .{ .kind = .maven, .path = pom_path }, pom_contents);
        return;
    }

    if (std.mem.eql(u8, system, "gradle")) {
        const gradle_kts = try std.fs.path.join(allocator, &.{ root, "build.gradle.kts" });
        defer allocator.free(gradle_kts);
        const gradle_groovy = try std.fs.path.join(allocator, &.{ root, "build.gradle" });
        defer allocator.free(gradle_groovy);

        const build_file = if (project_io.pathExistsWithIO(io, gradle_kts))
            gradle_kts
        else if (project_io.pathExistsWithIO(io, gradle_groovy))
            gradle_groovy
        else
            return;

        const build_contents = try common.readFileAllocWithIO(io, allocator, build_file);
        defer allocator.free(build_contents);
        try emit.writeDirectOutputWithIO(io, stdout, allocator, .{ .kind = .gradle, .path = build_file }, build_contents);
    }
}

fn writeCFamilyAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, result: build_system.Result) !void {
    try writeSystemResult(stdout, result);
    const system = result.system orelse return;

    if (std.mem.eql(u8, system, "bazel")) {
        try writeBazelAutoOutputWithIO(io, stdout, allocator, options, result);
        return;
    }

    if (std.mem.eql(u8, system, "make")) {
        const auto_contents = try project_io.readProjectFileWithIO(io, allocator, .make_auto, options.path);
        defer allocator.free(auto_contents);
        try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
            .kind = .make_auto,
            .path = options.path,
            .project_root = result.root,
        }, auto_contents);
        return;
    }

    if (std.mem.eql(u8, system, "cmake")) {
        _ = try direct.writeCMakeAutoOutputWithIO(io, stdout, allocator, options);
        return;
    }

    if (std.mem.eql(u8, system, "meson")) {
        _ = try direct.writeMesonAutoOutputWithIO(io, stdout, allocator, options);
    }
}

fn writePythonAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options) !void {
    const pyproject_path = (try project_io.findParentFileAllocWithIO(io, allocator, options.path, "pyproject.toml", 12)) orelse return;
    defer allocator.free(pyproject_path);
    const pyproject_contents = try common.readFileAllocWithIO(io, allocator, pyproject_path);
    defer allocator.free(pyproject_contents);
    try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
        .kind = .python_auto,
        .path = pyproject_path,
    }, pyproject_contents);
}

fn writeBazelAutoOutput(stdout: anytype, allocator: std.mem.Allocator, options: Options, result: build_system.Result) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return writeBazelAutoOutputWithIO(threaded.io(), stdout, allocator, options, result);
}

fn writeBazelAutoOutputWithIO(io: std.Io, stdout: anytype, allocator: std.mem.Allocator, options: Options, result: build_system.Result) !void {
    const root = result.root orelse return;
    try emit.writeDirectOutputWithIO(io, stdout, allocator, .{
        .kind = .bazel_workspace,
        .path = root,
        .match_path = options.match_path orelse options.path,
    }, "");
}
