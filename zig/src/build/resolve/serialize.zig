const std = @import("std");
const config = @import("../../config.zig");
const command = @import("command.zig");
const common = @import("../../project/core/common.zig");
const build_types = @import("../system/types.zig");
const types = @import("types.zig");

pub fn writeResolvedOutputJson(
    stdout: anytype,
    allocator: std.mem.Allocator,
    parsed_output: types.ResolvedOutput,
    filetype: []const u8,
    live_name: ?[]const u8,
    last_command_name: ?[]const u8,
) !void {
    const has_commands = parsed_output.commands.items.len > 0;
    const reason: ?[]const u8 = if (has_commands) null else "no_build_commands";
    const message: ?[]u8 = if (has_commands)
        null
    else
        try std.fmt.allocPrint(allocator, "No build commands available for filetype: {s}", .{filetype});
    defer if (message) |value| allocator.free(value);

    const command_meta = try buildCommandMetaJson(allocator, filetype, parsed_output.commands.items);
    defer freeCommandMetaJson(allocator, command_meta);
    const command_entries = try buildPickerCommandEntries(allocator, parsed_output.commands.items, command_meta, last_command_name);
    defer freePickerCommandEntries(allocator, command_entries);
    const completion_names = try buildCompletionNames(allocator, command_entries);
    defer allocator.free(completion_names);

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();

    const payload = BuildResolvedJson{
        .ok = has_commands,
        .reason = reason,
        .message = message,
        .root = parsed_output.root,
        .filetype = filetype,
        .system = parsed_output.system,
        .build_ready = parsed_output.build_ready,
        .config_revision = config.getSyncedRevision(),
        .commands = parsed_output.commands.items,
        .command_meta = command_meta,
        .command_entries = command_entries,
        .completion_names = completion_names,
        .preferred_commands = parsed_output.preferred.items,
        .live_preferred_name = live_name,
        .last_command_name = last_command_name,
    };
    try std.json.Stringify.value(payload, .{}, &json_out.writer);
    try stdout.print("RESULT_JSON\t{s}\n", .{json_out.written()});
}

pub fn writeResolvedOutputLegacyHeader(
    stdout: anytype,
    parsed_output: types.ResolvedOutput,
    filetype: []const u8,
    last_command_name: ?[]const u8,
) !void {
    const has_commands = parsed_output.commands.items.len > 0;
    try stdout.print("OK\t{d}\n", .{if (has_commands) @as(u8, 1) else @as(u8, 0)});
    if (!has_commands) {
        try stdout.print("REASON\tno_build_commands\n", .{});
        try stdout.print("MESSAGE\tNo build commands available for filetype: {s}\n", .{filetype});
    }
    if (parsed_output.root) |root| {
        if (!common.hasControlChars(root)) {
            try stdout.print("ROOT\t{s}\n", .{root});
        }
    }
    try stdout.print("FILETYPE\t{s}\n", .{filetype});
    if (parsed_output.system) |system| {
        if (!common.hasControlChars(system)) {
            try stdout.print("SYSTEM\t{s}\n", .{system});
        }
    }
    if (parsed_output.build_ready) |ready| {
        try stdout.print("BUILD_READY\t{d}\n", .{if (ready) @as(u8, 1) else @as(u8, 0)});
    }
    if (last_command_name) |name| {
        if (!common.hasControlChars(name)) {
            try stdout.print("LAST_COMMAND_NAME\t{s}\n", .{name});
        }
    }
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});
}

pub fn writeResolvedOutputLegacyCommands(
    stdout: anytype,
    allocator: std.mem.Allocator,
    filetype: []const u8,
    entries: []const build_types.CommandEntry,
) !void {
    for (entries) |entry| {
        if (common.hasControlChars(entry.name) or common.hasControlChars(entry.command)) continue;
        try stdout.print("COMMAND\t{s}\t{s}\n", .{ entry.name, entry.command });
        try command.writeCommandUiMetadata(stdout, allocator, filetype, entry);
    }
}

pub fn writeResolvedOutputLegacyPreferred(
    stdout: anytype,
    entries: []const build_types.CommandEntry,
    live_name: ?[]const u8,
) !void {
    for (entries) |entry| {
        if (common.hasControlChars(entry.name) or common.hasControlChars(entry.command)) continue;
        try stdout.print("PREFERRED\t{s}\t{s}\n", .{ entry.name, entry.command });
    }
    if (live_name) |name| {
        if (!common.hasControlChars(name)) {
            try stdout.print("PREFERRED_NAME\tlive\t{s}\n", .{name});
        }
    }
}

pub fn writeResolvedCommandOutputJson(
    stdout: anytype,
    allocator: std.mem.Allocator,
    resolved_filetype: []const u8,
    cwd: []const u8,
    command_name: []const u8,
    resolved_command: []const u8,
    argv: []const []u8,
) !void {
    const display_name = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ resolved_filetype, command_name });
    defer allocator.free(display_name);

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();

    const payload = BuildResolvedCommandJson{
        .filetype = resolved_filetype,
        .cwd = cwd,
        .name = display_name,
        .exec_command = resolved_command,
        .exec_argv = argv,
        .config_revision = config.getSyncedRevision(),
    };
    try std.json.Stringify.value(payload, .{}, &json_out.writer);
    try stdout.print("RESULT_JSON\t{s}\n", .{json_out.written()});
}

pub fn writeResolvedCommandOutputLegacy(
    stdout: anytype,
    resolved_filetype: []const u8,
    cwd: []const u8,
    command_name: []const u8,
    resolved_command: []const u8,
    argv: []const []u8,
) !void {
    if (!common.hasControlChars(resolved_filetype)) {
        try stdout.print("FILETYPE\t{s}\n", .{resolved_filetype});
    }
    if (!common.hasControlChars(cwd)) {
        try stdout.print("CWD\t{s}\n", .{cwd});
    }
    if (!common.hasControlChars(resolved_filetype) and !common.hasControlChars(command_name)) {
        try stdout.print("NAME\t{s}: {s}\n", .{ resolved_filetype, command_name });
    }
    if (!common.hasControlChars(resolved_command)) {
        try stdout.print("EXEC_COMMAND\t{s}\n", .{resolved_command});
    }
    for (argv) |arg| {
        if (!common.hasControlChars(arg)) {
            try stdout.print("EXEC_ARGV\t{s}\n", .{arg});
        }
    }
    try stdout.print("CONFIG_REVISION\t{d}\n", .{config.getSyncedRevision()});
}

const BuildResolvedCommandJson = struct {
    filetype: []const u8,
    cwd: []const u8,
    name: []const u8,
    exec_command: []const u8,
    exec_argv: []const []u8,
    config_revision: u64,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("filetype");
        try jw.write(self.filetype);
        try jw.objectField("cwd");
        try jw.write(self.cwd);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("exec_command");
        try jw.write(self.exec_command);
        try jw.objectField("exec_argv");
        try jw.write(self.exec_argv);
        try jw.objectField("config_revision");
        try jw.write(self.config_revision);
        try jw.endObject();
    }
};

const BuildResolvedJson = struct {
    ok: bool,
    reason: ?[]const u8,
    message: ?[]const u8,
    root: ?[]const u8,
    filetype: []const u8,
    system: ?[]const u8,
    build_ready: ?bool,
    config_revision: u64,
    commands: []const build_types.CommandEntry,
    command_meta: []const CommandMetaJson,
    command_entries: []const PickerCommandEntryJson,
    completion_names: []const []const u8,
    preferred_commands: []const build_types.CommandEntry,
    live_preferred_name: ?[]const u8,
    last_command_name: ?[]const u8,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(self.ok);
        if (self.reason) |reason| {
            try jw.objectField("reason");
            try jw.write(reason);
        }
        if (self.message) |message| {
            try jw.objectField("message");
            try jw.write(message);
        }
        if (self.root) |root| {
            try jw.objectField("root");
            try jw.write(root);
        }
        try jw.objectField("filetype");
        try jw.write(self.filetype);
        if (self.system) |system| {
            try jw.objectField("system");
            try jw.write(system);
        }
        if (self.build_ready) |ready| {
            try jw.objectField("build_ready");
            try jw.write(ready);
        }
        try jw.objectField("config_revision");
        try jw.write(self.config_revision);
        try jw.objectField("commands");
        try writeCommandMap(jw, self.commands);
        try jw.objectField("command_meta");
        try writeCommandMetaMap(jw, self.command_meta);
        try jw.objectField("command_entries");
        try jw.write(self.command_entries);
        try jw.objectField("completion_names");
        try jw.write(self.completion_names);
        try jw.objectField("preferred_commands");
        try writeCommandMap(jw, self.preferred_commands);
        try jw.objectField("preferred_names");
        try jw.beginObject();
        if (self.live_preferred_name) |name| {
            try jw.objectField("live");
            try jw.write(name);
        }
        try jw.endObject();
        if (self.last_command_name) |name| {
            try jw.objectField("last_command_name");
            try jw.write(name);
        }
        try jw.endObject();
    }
};

fn writeCommandMap(jw: anytype, entries: []const build_types.CommandEntry) !void {
    try jw.beginObject();
    for (entries) |entry| {
        try jw.objectField(entry.name);
        try jw.write(entry.command);
    }
    try jw.endObject();
}

fn writeCommandMetaMap(jw: anytype, entries: []const CommandMetaJson) !void {
    try jw.beginObject();
    for (entries) |entry| {
        try jw.objectField(entry.name);
        try jw.beginObject();
        try jw.objectField("display_command");
        try jw.write(entry.display_command);
        try jw.objectField("picker_section");
        try jw.write(entry.picker_section);
        try jw.objectField("picker_rank");
        try jw.write(entry.picker_rank);
        if (entry.hide_in_picker) {
            try jw.objectField("hide_in_picker");
            try jw.write(true);
        }
        if (entry.requires_arguments) {
            try jw.objectField("requires_arguments");
            try jw.write(true);
            try jw.objectField("argument_prompt");
            try jw.write(entry.argument_prompt.?);
            try jw.objectField("argument_help");
            try jw.write(entry.argument_help.?);
        }
        try jw.endObject();
    }
    try jw.endObject();
}

const CommandMetaJson = struct {
    name: []const u8,
    display_command: []const u8,
    requires_arguments: bool,
    argument_prompt: ?[]const u8,
    argument_help: ?[]const u8,
    picker_section: []const u8,
    picker_rank: usize,
    hide_in_picker: bool,
};

const PickerCommandEntryJson = struct {
    name: []const u8,
    command: []const u8,
    display_command: []const u8,
    requires_arguments: bool,
    argument_prompt: ?[]const u8,
    argument_help: ?[]const u8,
    picker_section: []const u8,
    picker_rank: usize,
};

fn buildCommandMetaJson(
    allocator: std.mem.Allocator,
    filetype: []const u8,
    entries: []const build_types.CommandEntry,
) ![]CommandMetaJson {
    const meta = try allocator.alloc(CommandMetaJson, entries.len);
    var initialized: usize = 0;
    errdefer {
        for (meta[0..initialized]) |entry| {
            allocator.free(entry.display_command);
            if (entry.argument_prompt) |prompt| allocator.free(prompt);
            if (entry.argument_help) |help| allocator.free(help);
        }
        allocator.free(meta);
    }

    for (entries, 0..) |entry, index| {
        const requires_arguments = command.commandRequiresArguments(entry.command);
        const display_command = try command.commandDisplayAlloc(allocator, entry.command);
        var argument_prompt: ?[]u8 = null;
        var argument_help: ?[]u8 = null;
        if (requires_arguments) {
            argument_prompt = command.commandArgumentPromptAlloc(allocator, filetype, entry.name) catch |err| {
                allocator.free(display_command);
                return err;
            };
            argument_help = command.commandArgumentHelpAlloc(allocator, filetype, entry.name) catch |err| {
                allocator.free(display_command);
                if (argument_prompt) |prompt| allocator.free(prompt);
                return err;
            };
        }

        meta[index] = .{
            .name = entry.name,
            .display_command = display_command,
            .requires_arguments = requires_arguments,
            .argument_prompt = argument_prompt,
            .argument_help = argument_help,
            .picker_section = pickerSection(entry.name),
            .picker_rank = pickerRank(entry.name),
            .hide_in_picker = shouldHideInPicker(filetype, entries, entry),
        };
        initialized = index + 1;
    }

    return meta;
}

fn freeCommandMetaJson(allocator: std.mem.Allocator, entries: []CommandMetaJson) void {
    for (entries) |entry| {
        allocator.free(entry.display_command);
        if (entry.argument_prompt) |prompt| allocator.free(prompt);
        if (entry.argument_help) |help| allocator.free(help);
    }
    allocator.free(entries);
}

fn buildPickerCommandEntries(
    allocator: std.mem.Allocator,
    commands: []const build_types.CommandEntry,
    meta_entries: []const CommandMetaJson,
    last_command_name: ?[]const u8,
) ![]PickerCommandEntryJson {
    var entries: std.ArrayList(PickerCommandEntryJson) = .empty;
    defer entries.deinit(allocator);

    for (commands, meta_entries) |command_entry, meta_entry| {
        if (meta_entry.hide_in_picker) continue;
        try entries.append(allocator, .{
            .name = command_entry.name,
            .command = command_entry.command,
            .display_command = meta_entry.display_command,
            .requires_arguments = meta_entry.requires_arguments,
            .argument_prompt = meta_entry.argument_prompt,
            .argument_help = meta_entry.argument_help,
            .picker_section = meta_entry.picker_section,
            .picker_rank = meta_entry.picker_rank,
        });
    }

    std.mem.sort(PickerCommandEntryJson, entries.items, last_command_name, struct {
        fn lessThan(last_name: ?[]const u8, lhs: PickerCommandEntryJson, rhs: PickerCommandEntryJson) bool {
            if (last_name) |name| {
                const lhs_is_last = std.mem.eql(u8, lhs.name, name);
                const rhs_is_last = std.mem.eql(u8, rhs.name, name);
                if (lhs_is_last != rhs_is_last) return lhs_is_last;
            }
            if (lhs.picker_rank == rhs.picker_rank) {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
            return lhs.picker_rank < rhs.picker_rank;
        }
    }.lessThan);

    return entries.toOwnedSlice(allocator);
}

fn freePickerCommandEntries(allocator: std.mem.Allocator, entries: []PickerCommandEntryJson) void {
    allocator.free(entries);
}

fn buildCompletionNames(
    allocator: std.mem.Allocator,
    entries: []const PickerCommandEntryJson,
) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, index| {
        names[index] = entry.name;
    }
    return names;
}

fn splitCommandPrefix(cmd_name: []const u8) struct { prefix: ?[]const u8, rest: ?[]const u8 } {
    const dash_idx = std.mem.findScalar(u8, cmd_name, '-') orelse return .{ .prefix = null, .rest = null };
    if (dash_idx == 0 or dash_idx + 1 >= cmd_name.len) return .{ .prefix = null, .rest = null };
    return .{
        .prefix = cmd_name[0..dash_idx],
        .rest = cmd_name[dash_idx + 1 ..],
    };
}

fn commonCommandOrder(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "build")) return 1;
    if (std.mem.eql(u8, name, "run")) return 2;
    if (std.mem.eql(u8, name, "clean")) return 3;
    if (std.mem.eql(u8, name, "test")) return 4;
    if (std.mem.eql(u8, name, "install")) return 5;
    if (std.mem.eql(u8, name, "check")) return 6;
    if (std.mem.eql(u8, name, "dev")) return 7;
    if (std.mem.eql(u8, name, "start")) return 8;
    if (std.mem.eql(u8, name, "watch")) return 9;
    if (std.mem.eql(u8, name, "serve")) return 10;
    if (std.mem.eql(u8, name, "preview")) return 11;
    if (std.mem.eql(u8, name, "mod")) return 12;
    if (std.mem.eql(u8, name, "fetch")) return 13;
    return null;
}

fn profileCommandOrder(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "config")) return 1;
    if (std.mem.eql(u8, name, "setup")) return 2;
    if (std.mem.eql(u8, name, "debug")) return 3;
    if (std.mem.eql(u8, name, "release")) return 4;
    return null;
}

fn pickerSection(name: []const u8) []const u8 {
    const split = splitCommandPrefix(name);
    const semantic_name = split.rest orelse name;

    if (split.prefix) |prefix| {
        if ((std.mem.eql(u8, prefix, "cmake") or std.mem.eql(u8, prefix, "meson")) and split.rest != null) {
            const rest = split.rest.?;
            if (std.mem.startsWith(u8, rest, "build-") or std.mem.startsWith(u8, rest, "run-")) return "targets";
            if (commonCommandOrder(rest) != null) return "common";
            if (profileCommandOrder(rest) != null) return "profiles";
        }
    }

    if (commonCommandOrder(semantic_name) != null) return "common";
    if (profileCommandOrder(semantic_name) != null) return "profiles";
    return "other";
}

fn pickerRank(name: []const u8) usize {
    const split = splitCommandPrefix(name);
    const semantic_name = split.rest orelse name;
    const section = pickerSection(name);
    const section_rank: usize = if (std.mem.eql(u8, section, "common"))
        1
    else if (std.mem.eql(u8, section, "targets"))
        2
    else if (std.mem.eql(u8, section, "profiles"))
        3
    else
        4;
    const name_rank = commonCommandOrder(semantic_name) orelse profileCommandOrder(semantic_name) orelse 999;
    return section_rank * 1000 + name_rank;
}

fn isCFamily(filetype: []const u8) bool {
    return std.mem.eql(u8, filetype, "c") or std.mem.eql(u8, filetype, "cpp");
}

fn findCommand(entries: []const build_types.CommandEntry, name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.command;
    }
    return null;
}

fn shouldHideInPicker(
    filetype: []const u8,
    entries: []const build_types.CommandEntry,
    entry: build_types.CommandEntry,
) bool {
    if (!isCFamily(filetype)) return false;
    const base_name = if (std.mem.startsWith(u8, entry.name, "cmake-"))
        entry.name["cmake-".len..]
    else if (std.mem.startsWith(u8, entry.name, "meson-"))
        entry.name["meson-".len..]
    else
        return false;
    if (base_name.len == 0 or std.mem.findScalar(u8, base_name, '-') != null) return false;
    const generic_command = findCommand(entries, base_name) orelse return false;
    return std.mem.eql(u8, generic_command, entry.command);
}

test "buildCommandMetaJson includes picker metadata and prunes redundant c-family aliases" {
    const allocator = std.testing.allocator;
    const entries = [_]build_types.CommandEntry{
        .{ .name = "build", .command = @constCast("cmake --build build") },
        .{ .name = "cmake-build", .command = @constCast("cmake --build build") },
        .{ .name = "cmake-build-demo", .command = @constCast("cmake --build build --target demo") },
        .{ .name = "debug", .command = @constCast("cmake -DCMAKE_BUILD_TYPE=Debug -S . -B build") },
    };

    const meta = try buildCommandMetaJson(allocator, "c", &entries);
    defer freeCommandMetaJson(allocator, meta);

    try std.testing.expectEqualStrings("common", meta[0].picker_section);
    try std.testing.expectEqual(@as(usize, 1001), meta[0].picker_rank);
    try std.testing.expect(!meta[0].hide_in_picker);

    try std.testing.expectEqualStrings("common", meta[1].picker_section);
    try std.testing.expect(meta[1].hide_in_picker);

    try std.testing.expectEqualStrings("targets", meta[2].picker_section);
    try std.testing.expectEqual(@as(usize, 2999), meta[2].picker_rank);
    try std.testing.expect(!meta[2].hide_in_picker);

    try std.testing.expectEqualStrings("profiles", meta[3].picker_section);
    try std.testing.expectEqual(@as(usize, 3003), meta[3].picker_rank);
}

test "buildPickerCommandEntries sorts picker entries with last command first" {
    const allocator = std.testing.allocator;
    const commands = [_]build_types.CommandEntry{
        .{ .name = "build", .command = @constCast("echo build") },
        .{ .name = "test", .command = @constCast("echo test") },
        .{ .name = "cmake-build", .command = @constCast("echo build") },
    };
    const meta = [_]CommandMetaJson{
        .{
            .name = "build",
            .display_command = "echo build",
            .requires_arguments = false,
            .argument_prompt = null,
            .argument_help = null,
            .picker_section = "common",
            .picker_rank = 1001,
            .hide_in_picker = false,
        },
        .{
            .name = "test",
            .display_command = "echo test",
            .requires_arguments = false,
            .argument_prompt = null,
            .argument_help = null,
            .picker_section = "common",
            .picker_rank = 1004,
            .hide_in_picker = false,
        },
        .{
            .name = "cmake-build",
            .display_command = "echo build",
            .requires_arguments = false,
            .argument_prompt = null,
            .argument_help = null,
            .picker_section = "common",
            .picker_rank = 1001,
            .hide_in_picker = true,
        },
    };

    const entries = try buildPickerCommandEntries(allocator, &commands, &meta, "test");
    defer freePickerCommandEntries(allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("test", entries[0].name);
    try std.testing.expectEqualStrings("build", entries[1].name);
}

test "buildCompletionNames preserves backend picker order" {
    const allocator = std.testing.allocator;
    const entries = [_]PickerCommandEntryJson{
        .{
            .name = "test",
            .command = @constCast("echo test"),
            .display_command = "echo test",
            .requires_arguments = false,
            .argument_prompt = null,
            .argument_help = null,
            .picker_section = "common",
            .picker_rank = 1004,
        },
        .{
            .name = "build",
            .command = @constCast("echo build"),
            .display_command = "echo build",
            .requires_arguments = false,
            .argument_prompt = null,
            .argument_help = null,
            .picker_section = "common",
            .picker_rank = 1001,
        },
    };

    const names = try buildCompletionNames(allocator, &entries);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("test", names[0]);
    try std.testing.expectEqualStrings("build", names[1]);
}

test "writeResolvedOutputJson reports no_build_commands when command list is empty" {
    const allocator = std.testing.allocator;

    var parsed_output: types.ResolvedOutput = .{};
    defer parsed_output.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeResolvedOutputJson(&out.writer, allocator, parsed_output, "unknownft", null, null);

    try std.testing.expect(std.mem.find(u8, out.written(), "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"reason\":\"no_build_commands\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"message\":\"No build commands available for filetype: unknownft\"") != null);
}
