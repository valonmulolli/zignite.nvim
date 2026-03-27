const std = @import("std");
const config = @import("../../config.zig");
const filetype_resolver = @import("../../filetype.zig");
const build_system = @import("../system.zig");
const build_types = @import("../system/types.zig");
const project = @import("../../project.zig");
const project_types = @import("../../project/core/types.zig");
const types = @import("types.zig");

pub fn resolveOutput(allocator: std.mem.Allocator, options: types.Options) !types.ResolvedOutput {
    var parsed_output = try resolveDetectedOutput(allocator, options);
    errdefer parsed_output.deinit(allocator);
    const resolved_filetype = parsed_output.filetype orelse options.filetype;

    const configured = try collectConfiguredCommands(allocator, resolved_filetype, options.path);
    defer types.freeOwnedCommands(allocator, configured);

    for (configured) |entry| {
        if (!shouldOverlayConfiguredCommand(resolved_filetype, parsed_output.commands.items, entry)) continue;
        try upsertOwnedCommand(&parsed_output.commands, allocator, entry.name, entry.command);
    }
    return parsed_output;
}

pub fn resolveDetectedOutput(allocator: std.mem.Allocator, options: types.Options) !types.ResolvedOutput {
    const resolved_filetype = try filetype_resolver.resolveSupportedAlloc(allocator, options.filetype, options.path);
    defer allocator.free(resolved_filetype);

    var resolved = try collectSystemOutput(allocator, options, resolved_filetype);
    errdefer resolved.deinit(allocator);
    resolved.filetype = try allocator.dupe(u8, resolved_filetype);

    var project_output = try collectAutoProjectOutput(allocator, options, resolved_filetype);
    defer project_output.deinit(allocator);
    try mergeResolvedOutput(allocator, &resolved, project_output);

    return resolved;
}

pub fn appendImplicitPreferred(
    allocator: std.mem.Allocator,
    preferred: *std.ArrayList(build_types.CommandEntry),
    commands: []const build_types.CommandEntry,
) !void {
    const keys = [_][]const u8{ "build", "run", "live", "test", "clean" };
    for (keys) |key| {
        if (findCommand(preferred.items, key) != null) continue;
        const command = findCommand(commands, key) orelse continue;
        try upsertOwnedCommand(preferred, allocator, key, command);
    }
}

pub fn findCommand(commands: []const build_types.CommandEntry, name: []const u8) ?[]const u8 {
    for (commands) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

pub fn upsertOwnedCommand(
    commands: *std.ArrayList(build_types.CommandEntry),
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []const u8,
) !void {
    for (commands.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        allocator.free(entry.command);
        entry.command = try allocator.dupe(u8, command);
        return;
    }

    try commands.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .command = try allocator.dupe(u8, command),
    });
}

fn collectConfiguredCommands(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    path: []const u8,
) ![]build_types.CommandEntry {
    const raw = config.getSyncedConfigJson() orelse return allocator.alloc(build_types.CommandEntry, 0);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return allocator.alloc(build_types.CommandEntry, 0);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return allocator.alloc(build_types.CommandEntry, 0);

    const build_commands = root.object.get("build_commands") orelse return allocator.alloc(build_types.CommandEntry, 0);
    if (build_commands != .object) return allocator.alloc(build_types.CommandEntry, 0);

    const filetype_commands = build_commands.object.get(filetype) orelse return allocator.alloc(build_types.CommandEntry, 0);
    if (filetype_commands != .object) return allocator.alloc(build_types.CommandEntry, 0);

    var commands = try std.ArrayList(build_types.CommandEntry).initCapacity(allocator, filetype_commands.object.count());
    errdefer {
        types.freeOwnedCommands(allocator, commands.items);
        commands.deinit(allocator);
    }

    var it = filetype_commands.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try commands.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .command = try substituteVariablesShellAlloc(allocator, entry.value_ptr.string, path),
        });
    }

    return try commands.toOwnedSlice(allocator);
}

fn collectAutoProjectOutput(
    allocator: std.mem.Allocator,
    options: types.Options,
    filetype: []const u8,
) !types.ResolvedOutput {
    const kind = autoKindForFiletype(filetype);
    if (kind == null or !isDetectionEnabled(allocator, filetype)) {
        return .{};
    }

    const project_options = project.Options{
        .kind = kind.?,
        .path = options.path,
        .match_path = options.path,
        .project_root = options.project_root,
    };

    const contents = try project.readProjectFile(allocator, project_options.kind, project_options.path);
    defer allocator.free(contents);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try project.writeOutput(output.writer(allocator), allocator, project_options, contents);

    return try parseProjectOutput(allocator, output.items);
}

fn collectSystemOutput(
    allocator: std.mem.Allocator,
    options: types.Options,
    filetype: []const u8,
) !types.ResolvedOutput {
    const query = systemQueryForFiletype(filetype);
    if (query == null or !isDetectionEnabled(allocator, filetype)) {
        return .{};
    }

    const result = try build_system.detect(allocator, query.?, options.path, options.project_root);
    defer build_system.freeOwnedResult(allocator, result);

    return try resolvedOutputFromSystemResult(allocator, result);
}

fn parseProjectOutput(allocator: std.mem.Allocator, output: []const u8) !types.ResolvedOutput {
    var parsed: types.ResolvedOutput = .{};
    errdefer parsed.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "ROOT\t")) {
            parsed.root = try allocator.dupe(u8, line["ROOT\t".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "SYSTEM\t")) {
            parsed.system = try allocator.dupe(u8, line["SYSTEM\t".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "BUILD_READY\t")) {
            parsed.build_ready = std.mem.eql(u8, line["BUILD_READY\t".len..], "1");
            continue;
        }

        const first = splitFirstTab(line) orelse continue;
        if (!std.mem.eql(u8, first[0], "COMMAND") and !std.mem.eql(u8, first[0], "PREFERRED")) continue;
        const second = splitFirstTab(first[1]) orelse continue;
        if (second[0].len == 0 or second[1].len == 0) continue;

        if (std.mem.eql(u8, first[0], "COMMAND")) {
            try upsertOwnedCommand(&parsed.commands, allocator, second[0], second[1]);
        } else {
            try upsertOwnedCommand(&parsed.preferred, allocator, second[0], second[1]);
        }
    }

    return parsed;
}

fn autoKindForFiletype(filetype: []const u8) ?project_types.Kind {
    if (std.mem.eql(u8, filetype, "c") or std.mem.eql(u8, filetype, "cpp")) return .c_family_auto;
    if (std.mem.eql(u8, filetype, "rust")) return .cargo_auto;
    if (std.mem.eql(u8, filetype, "go")) return .go_auto;
    if (std.mem.eql(u8, filetype, "java") or std.mem.eql(u8, filetype, "kotlin")) return .jvm_auto;
    if (std.mem.eql(u8, filetype, "javascript") or std.mem.eql(u8, filetype, "typescript")) return .package_json_auto;
    if (std.mem.eql(u8, filetype, "python")) return .python_auto;
    if (std.mem.eql(u8, filetype, "bzl")) return .bazel_auto;
    return null;
}

fn systemQueryForFiletype(filetype: []const u8) ?build_system.Query {
    if (std.mem.eql(u8, filetype, "c") or std.mem.eql(u8, filetype, "cpp")) return .c_family;
    if (std.mem.eql(u8, filetype, "java") or std.mem.eql(u8, filetype, "kotlin")) return .jvm_root;
    if (std.mem.eql(u8, filetype, "javascript") or std.mem.eql(u8, filetype, "typescript")) return .node_root;
    if (std.mem.eql(u8, filetype, "python")) return .python_root;
    if (std.mem.eql(u8, filetype, "bzl")) return .bazel_root;
    return null;
}

fn isDetectionEnabled(allocator: std.mem.Allocator, filetype: []const u8) bool {
    const raw = config.getSyncedConfigJson() orelse return true;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return true;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return true;
    const detect = root.object.get("detect") orelse return true;
    if (detect != .object) return true;

    const detect_key =
        if (std.mem.eql(u8, filetype, "c") or std.mem.eql(u8, filetype, "cpp"))
            "c_cpp_make"
        else if (std.mem.eql(u8, filetype, "javascript") or std.mem.eql(u8, filetype, "typescript"))
            "js_package_scripts"
        else if (std.mem.eql(u8, filetype, "java") or std.mem.eql(u8, filetype, "kotlin"))
            "java_kotlin_project"
        else if (std.mem.eql(u8, filetype, "bzl"))
            "bazel_project"
        else
            return true;

    const enabled = detect.object.get(detect_key) orelse return true;
    if (enabled != .bool) return true;
    return enabled.bool;
}

fn shouldOverlayConfiguredCommand(
    filetype: []const u8,
    commands: []const build_types.CommandEntry,
    configured: build_types.CommandEntry,
) bool {
    if (findCommand(commands, configured.name) == null) return true;
    const builtin = builtinConfiguredCommand(filetype, configured.name) orelse return true;
    return !std.mem.eql(u8, builtin, configured.command);
}

fn builtinConfiguredCommand(filetype: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, filetype, "rust")) {
        if (std.mem.eql(u8, name, "build")) return "cargo build";
        if (std.mem.eql(u8, name, "run")) return "cargo run";
        if (std.mem.eql(u8, name, "test")) return "cargo test";
        if (std.mem.eql(u8, name, "release")) return "cargo build --release";
        if (std.mem.eql(u8, name, "release-run")) return "cargo run --release";
        if (std.mem.eql(u8, name, "check")) return "cargo check";
        if (std.mem.eql(u8, name, "clean")) return "cargo clean";
        return null;
    }
    if (std.mem.eql(u8, filetype, "zig")) {
        if (std.mem.eql(u8, name, "build")) return "zig build";
        if (std.mem.eql(u8, name, "run")) return "zig build run";
        if (std.mem.eql(u8, name, "test")) return "zig build test";
        if (std.mem.eql(u8, name, "check")) return "zig build check";
        if (std.mem.eql(u8, name, "release")) return "zig build -Doptimize=ReleaseFast";
        if (std.mem.eql(u8, name, "release-run")) return "zig build run -Doptimize=ReleaseFast";
        return null;
    }
    if (std.mem.eql(u8, filetype, "odin")) {
        if (std.mem.eql(u8, name, "build")) return "odin build .";
        if (std.mem.eql(u8, name, "run")) return "odin run .";
        if (std.mem.eql(u8, name, "test")) return "odin test .";
        if (std.mem.eql(u8, name, "release")) return "odin build . -o:speed";
        if (std.mem.eql(u8, name, "check")) return "odin check .";
        return null;
    }
    if (std.mem.eql(u8, filetype, "fortran")) {
        if (std.mem.eql(u8, name, "build")) return "gfortran *.f90 -o main";
        if (std.mem.eql(u8, name, "run")) return "./main";
        if (std.mem.eql(u8, name, "clean")) return "rm -f main";
        return null;
    }
    if (std.mem.eql(u8, filetype, "go")) {
        if (std.mem.eql(u8, name, "build")) return "go build";
        if (std.mem.eql(u8, name, "run")) return "go run .";
        if (std.mem.eql(u8, name, "test")) return "go test ./...";
        if (std.mem.eql(u8, name, "clean")) return "go clean";
        if (std.mem.eql(u8, name, "mod")) return "go mod tidy";
        return null;
    }
    if (std.mem.eql(u8, filetype, "javascript")) {
        if (std.mem.eql(u8, name, "start")) return "npm start";
        if (std.mem.eql(u8, name, "dev")) return "npm run dev";
        if (std.mem.eql(u8, name, "build")) return "npm run build";
        if (std.mem.eql(u8, name, "test")) return "npm test";
        if (std.mem.eql(u8, name, "install")) return "npm install";
        return null;
    }
    if (std.mem.eql(u8, filetype, "typescript")) {
        if (std.mem.eql(u8, name, "start")) return "npm start";
        if (std.mem.eql(u8, name, "dev")) return "npm run dev";
        if (std.mem.eql(u8, name, "build")) return "npm run build";
        if (std.mem.eql(u8, name, "test")) return "npm test";
        return null;
    }
    if (std.mem.eql(u8, filetype, "python")) {
        if (std.mem.eql(u8, name, "run")) return "python -m main";
        if (std.mem.eql(u8, name, "test")) return "pytest";
        if (std.mem.eql(u8, name, "install")) return "pip install -r requirements.txt";
        return null;
    }
    if (std.mem.eql(u8, filetype, "c")) {
        if (std.mem.eql(u8, name, "build")) return "make";
        if (std.mem.eql(u8, name, "run")) return "make run";
        if (std.mem.eql(u8, name, "clean")) return "make clean";
        if (std.mem.eql(u8, name, "test")) return "make test";
        if (std.mem.eql(u8, name, "install")) return "make install";
        if (std.mem.eql(u8, name, "debug")) return "make debug";
        if (std.mem.eql(u8, name, "cmake-config")) return "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1";
        if (std.mem.eql(u8, name, "cmake-build")) return "cmake --build build";
        if (std.mem.eql(u8, name, "cmake-run")) return "cmake --build build && ./build/main";
        if (std.mem.eql(u8, name, "cmake-clean")) return "cmake --build build --target clean";
        return null;
    }
    if (std.mem.eql(u8, filetype, "cpp")) {
        if (std.mem.eql(u8, name, "build")) return "make";
        if (std.mem.eql(u8, name, "run")) return "make run";
        if (std.mem.eql(u8, name, "clean")) return "make clean";
        if (std.mem.eql(u8, name, "test")) return "make test";
        if (std.mem.eql(u8, name, "install")) return "make install";
        if (std.mem.eql(u8, name, "debug")) return "make debug";
        if (std.mem.eql(u8, name, "cmake-config")) return "cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=1";
        if (std.mem.eql(u8, name, "cmake-build")) return "cmake --build build";
        if (std.mem.eql(u8, name, "cmake-run")) return "cmake --build build && ./build/main";
        if (std.mem.eql(u8, name, "cmake-clean")) return "cmake --build build --target clean";
        return null;
    }
    return null;
}

fn resolvedOutputFromSystemResult(allocator: std.mem.Allocator, result: build_system.Result) !types.ResolvedOutput {
    var resolved: types.ResolvedOutput = .{
        .build_ready = result.build_ready,
    };
    errdefer resolved.deinit(allocator);

    if (result.root) |root| {
        resolved.root = try allocator.dupe(u8, root);
    }
    if (result.system) |system| {
        resolved.system = try allocator.dupe(u8, system);
    }
    for (result.commands) |entry| {
        try upsertOwnedCommand(&resolved.commands, allocator, entry.name, entry.command);
    }

    return resolved;
}

fn mergeResolvedOutput(
    allocator: std.mem.Allocator,
    base: *types.ResolvedOutput,
    overlay: types.ResolvedOutput,
) !void {
    if (overlay.root) |root| {
        if (base.root) |existing| allocator.free(existing);
        base.root = try allocator.dupe(u8, root);
    }
    if (overlay.system) |system| {
        if (base.system) |existing| allocator.free(existing);
        base.system = try allocator.dupe(u8, system);
    }
    if (overlay.build_ready != null) {
        base.build_ready = overlay.build_ready;
    }
    for (overlay.commands.items) |entry| {
        try upsertOwnedCommand(&base.commands, allocator, entry.name, entry.command);
    }
    for (overlay.preferred.items) |entry| {
        try upsertOwnedCommand(&base.preferred, allocator, entry.name, entry.command);
    }
}

fn splitFirstTab(line: []const u8) ?struct { [2][]const u8 } {
    const index = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    return .{ .{ line[0..index], line[index + 1 ..] } };
}

fn substituteVariablesShellAlloc(
    allocator: std.mem.Allocator,
    template: []const u8,
    path: []const u8,
) ![]u8 {
    const file = path;
    const dir = std.fs.path.dirname(path) orelse path;
    const file_name = std.fs.path.basename(path);
    const file_name_without_ext = std.fs.path.stem(file_name);
    const file_ext = if (std.fs.path.extension(file_name)) |ext|
        if (ext.len > 0) ext[1..] else ""
    else
        "";
    const dir_name = std.fs.path.basename(dir);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '%' and index + 1 < template.len and template[index + 1] == '%') {
            try appendShellValue(allocator, &out, file);
            index += 2;
            continue;
        }
        if (template[index] != '$') {
            try out.append(allocator, template[index]);
            index += 1;
            continue;
        }

        var end: usize = index + 1;
        while (end < template.len and (std.ascii.isAlphanumeric(template[end]) or template[end] == '_')) : (end += 1) {}
        if (end == index + 1) {
            try out.append(allocator, template[index]);
            index += 1;
            continue;
        }

        const name = template[index + 1 .. end];
        const replacement = if (std.mem.eql(u8, name, "dir") or std.mem.eql(u8, name, "DIR"))
            dir
        else if (std.mem.eql(u8, name, "file") or std.mem.eql(u8, name, "FILE"))
            file
        else if (std.mem.eql(u8, name, "fileName") or std.mem.eql(u8, name, "FILENAME"))
            file_name
        else if (std.mem.eql(u8, name, "fileNameWithoutExt") or std.mem.eql(u8, name, "FILENAMEWITHOUTEXT"))
            file_name_without_ext
        else if (std.mem.eql(u8, name, "fileExt"))
            file_ext
        else if (std.mem.eql(u8, name, "dirName"))
            dir_name
        else
            null;

        if (replacement) |value| {
            try appendShellValue(allocator, &out, value);
        } else {
            try out.appendSlice(allocator, template[index..end]);
        }
        index = end;
    }

    return out.toOwnedSlice(allocator);
}

fn appendShellValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\"'\"'");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
}
