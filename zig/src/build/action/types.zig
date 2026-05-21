const std = @import("std");

pub const Action = enum {
    named,
    live,
    last,
};

pub const Options = struct {
    path: []const u8,
    filetype: []const u8,
    action: Action,
    command_name: ?[]const u8 = null,
    command_args: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
};

pub const FailureReason = enum {
    missing_command,
    missing_live_command,
    missing_last_command,
    stale_last_command,
    missing_arguments,
};

pub const Plan = struct {
    ok: bool,
    reason: ?FailureReason = null,
    message: ?[]u8 = null,
    resolved_command_name: ?[]u8 = null,
    requires_arguments: bool = false,
    argument_prompt: ?[]u8 = null,
    argument_help: ?[]u8 = null,
    filetype: ?[]u8 = null,
    cwd: ?[]u8 = null,
    name: ?[]u8 = null,
    exec_command: ?[]u8 = null,
    exec_argv: std.ArrayList([]u8) = .empty,
    config_revision: u64 = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        if (self.resolved_command_name) |value| allocator.free(value);
        if (self.argument_prompt) |value| allocator.free(value);
        if (self.argument_help) |value| allocator.free(value);
        if (self.filetype) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.name) |value| allocator.free(value);
        if (self.exec_command) |value| allocator.free(value);
        for (self.exec_argv.items) |arg| allocator.free(arg);
        self.exec_argv.deinit(allocator);
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("ok");
        try jw.write(self.ok);
        if (self.reason) |reason| {
            try jw.objectField("reason");
            try jw.write(@tagName(reason));
        }
        if (self.message) |message| {
            try jw.objectField("message");
            try jw.write(message);
        }
        if (self.resolved_command_name) |name| {
            try jw.objectField("resolved_command_name");
            try jw.write(name);
        }
        if (self.requires_arguments) {
            try jw.objectField("requires_arguments");
            try jw.write(true);
        }
        if (self.argument_prompt) |prompt| {
            try jw.objectField("argument_prompt");
            try jw.write(prompt);
        }
        if (self.argument_help) |help| {
            try jw.objectField("argument_help");
            try jw.write(help);
        }
        if (self.filetype) |filetype| {
            try jw.objectField("filetype");
            try jw.write(filetype);
        }
        if (self.cwd) |cwd| {
            try jw.objectField("cwd");
            try jw.write(cwd);
        }
        if (self.name) |name| {
            try jw.objectField("name");
            try jw.write(name);
        }
        if (self.exec_command) |command_text| {
            try jw.objectField("exec_command");
            try jw.write(command_text);
        }
        if (self.exec_argv.items.len > 0) {
            try jw.objectField("exec_argv");
            try jw.write(self.exec_argv.items);
        }
        try jw.objectField("config_revision");
        try jw.write(self.config_revision);
        try jw.endObject();
    }
};
