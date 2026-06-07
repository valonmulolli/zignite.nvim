const std = @import("std");

pub fn collectWarnings(allocator: std.mem.Allocator, json_payload: []const u8) ![][]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfigRoot;

    var warnings: std.ArrayList([]u8) = .empty;
    errdefer {
        freeWarnings(allocator, warnings.items);
        warnings.deinit(allocator);
    }

    try validateRoot(allocator, &warnings, parsed.value.object);
    return warnings.toOwnedSlice(allocator);
}

pub fn freeWarnings(allocator: std.mem.Allocator, warnings: [][]u8) void {
    for (warnings) |warning| allocator.free(warning);
    allocator.free(warnings);
}

fn validateRoot(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    root: std.json.ObjectMap,
) !void {
    if (root.get("runners")) |runners| {
        if (runners == .object) {
            try validateRunners(allocator, warnings, runners.object);
        } else {
            try pushWarning(allocator, warnings, "Invalid config runners: expected object, got {s}", .{valueTypeName(runners)});
        }
    }

    if (root.get("build_commands")) |build_commands| {
        if (build_commands == .object) {
            try validateBuildCommands(allocator, warnings, build_commands.object);
        } else {
            try pushWarning(
                allocator,
                warnings,
                "Invalid config build_commands: expected object, got {s}",
                .{valueTypeName(build_commands)},
            );
        }
    }

    if (root.get("detect")) |detect| {
        if (detect == .object) {
            try validateDetect(allocator, warnings, detect.object);
        } else {
            try pushWarning(allocator, warnings, "Invalid config detect: expected object, got {s}", .{valueTypeName(detect)});
        }
    }

    if (root.get("timeout")) |timeout| {
        try validateTimeout(allocator, warnings, timeout);
    }
}

fn validateRunners(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    runners: std.json.ObjectMap,
) !void {
    var it = runners.iterator();
    while (it.next()) |entry| {
        try validateRunner(allocator, warnings, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn validateRunner(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    filetype: []const u8,
    runner: std.json.Value,
) !void {
    switch (runner) {
        .string => {},
        .array => |items| {
            for (items.items, 0..) |item, index| {
                if (item != .string) {
                    try pushWarning(
                        allocator,
                        warnings,
                        "Invalid config runners.{s}[{d}]: expected string, got {s}",
                        .{ filetype, index, valueTypeName(item) },
                    );
                }
            }
        },
        .object => |obj| {
            const cmd = obj.get("cmd") orelse {
                try pushWarning(allocator, warnings, "Invalid config runners.{s}: missing cmd field", .{filetype});
                return;
            };
            switch (cmd) {
                .string => {},
                .array => |items| {
                    for (items.items, 0..) |item, index| {
                        if (item != .string) {
                            try pushWarning(
                                allocator,
                                warnings,
                                "Invalid config runners.{s}.cmd[{d}]: expected string, got {s}",
                                .{ filetype, index, valueTypeName(item) },
                            );
                        }
                    }
                },
                else => try pushWarning(
                    allocator,
                    warnings,
                    "Invalid config runners.{s}.cmd: expected string or string[], got {s}",
                    .{ filetype, valueTypeName(cmd) },
                ),
            }

            if (obj.get("cleanup_command")) |cleanup| {
                if (cleanup != .string) {
                    try pushWarning(
                        allocator,
                        warnings,
                        "Invalid config runners.{s}.cleanup_command: expected string, got {s}",
                        .{ filetype, valueTypeName(cleanup) },
                    );
                } else if (std.mem.indexOfAny(u8, cleanup.string, "\r\n\x00") != null) {
                    try pushWarning(
                        allocator,
                        warnings,
                        "Invalid config runners.{s}.cleanup_command: contains control characters",
                        .{filetype},
                    );
                }
            }

            if (obj.get("cwd")) |cwd| {
                if (cwd != .string) {
                    try pushWarning(
                        allocator,
                        warnings,
                        "Invalid config runners.{s}.cwd: expected string, got {s}",
                        .{ filetype, valueTypeName(cwd) },
                    );
                } else if (std.mem.indexOfAny(u8, cwd.string, "\r\n\x00") != null) {
                    try pushWarning(
                        allocator,
                        warnings,
                        "Invalid config runners.{s}.cwd: contains control characters",
                        .{filetype},
                    );
                }
            }
        },
        else => try pushWarning(
            allocator,
            warnings,
            "Invalid config runners.{s}: expected string, string[], or object, got {s}",
            .{ filetype, valueTypeName(runner) },
        ),
    }
}

fn validateBuildCommands(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    build_commands: std.json.ObjectMap,
) !void {
    var filetype_it = build_commands.iterator();
    while (filetype_it.next()) |filetype_entry| {
        if (filetype_entry.value_ptr.* != .object) {
            try pushWarning(
                allocator,
                warnings,
                "Invalid config build_commands.{s}: expected object, got {s}",
                .{ filetype_entry.key_ptr.*, valueTypeName(filetype_entry.value_ptr.*) },
            );
            continue;
        }

        var command_it = filetype_entry.value_ptr.object.iterator();
        while (command_it.next()) |command_entry| {
            if (command_entry.value_ptr.* != .string) {
                try pushWarning(
                    allocator,
                    warnings,
                    "Invalid config build_commands.{s}.{s}: expected string, got {s}",
                    .{ filetype_entry.key_ptr.*, command_entry.key_ptr.*, valueTypeName(command_entry.value_ptr.*) },
                );
            }
        }
    }
}

fn validateDetect(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    detect: std.json.ObjectMap,
) !void {
    var it = detect.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .bool) {
            try pushWarning(
                allocator,
                warnings,
                "Invalid config detect.{s}: expected boolean, got {s}",
                .{ entry.key_ptr.*, valueTypeName(entry.value_ptr.*) },
            );
        }
    }
}

fn validateTimeout(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    timeout: std.json.Value,
) !void {
    switch (timeout) {
        .integer => |value| {
            if (value <= 0) {
                try pushWarning(allocator, warnings, "Invalid config timeout: expected positive number, got {d}", .{value});
            }
        },
        .float => |value| {
            if (!std.math.isFinite(value) or value <= 0) {
                try pushWarning(allocator, warnings, "Invalid config timeout: expected positive number, got {d}", .{value});
            }
        },
        .null => {},
        else => try pushWarning(
            allocator,
            warnings,
            "Invalid config timeout: expected positive number or null, got {s}",
            .{valueTypeName(timeout)},
        ),
    }
}

fn pushWarning(
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList([]u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const warning = try std.fmt.allocPrint(allocator, fmt, args);
    warnings.append(allocator, warning) catch |err| {
        allocator.free(warning);
        return err;
    };
}

fn valueTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float => "float",
        .number_string => "number_string",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

test "collectWarnings reports malformed backend config entries" {
    const allocator = std.testing.allocator;
    const warnings = try collectWarnings(allocator,
        \\{
        \\  "runners": {
        \\    "zig": { "cmd": 42, "cleanup_command": false, "cwd": 9 },
        \\    "go": [1, "go run $file"]
        \\  },
        \\  "build_commands": {
        \\    "zig": { "build": ["zig", "build"] },
        \\    "go": true
        \\  },
        \\  "detect": {
        \\    "zig": "yes"
        \\  },
        \\  "timeout": "slow"
        \\}
    );
    defer freeWarnings(allocator, warnings);

    try std.testing.expect(warnings.len >= 7);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (warnings) |warning| {
        try joined.appendSlice(allocator, warning);
        try joined.append(allocator, '\n');
    }

    try std.testing.expect(std.mem.find(u8, joined.items, "runners.zig.cmd") != null);
    try std.testing.expect(std.mem.find(u8, joined.items, "runners.go[0]") != null);
    try std.testing.expect(std.mem.find(u8, joined.items, "build_commands.zig.build") != null);
    try std.testing.expect(std.mem.find(u8, joined.items, "detect.zig") != null);
    try std.testing.expect(std.mem.find(u8, joined.items, "timeout") != null);
}

test "collectWarnings accepts valid backend config entries" {
    const allocator = std.testing.allocator;
    const warnings = try collectWarnings(allocator,
        \\{
        \\  "runners": {
        \\    "cpp": { "cmd": ["c++ $file -o /tmp/out", "/tmp/out"], "cleanup_command": "rm -f /tmp/out", "cwd": "$dir" },
        \\    "go": "go run $file"
        \\  },
        \\  "build_commands": {
        \\    "zig": { "build": "zig build" }
        \\  },
        \\  "detect": { "zig": true },
        \\  "timeout": 1200
        \\}
    );
    defer freeWarnings(allocator, warnings);

    try std.testing.expectEqual(@as(usize, 0), warnings.len);
}

test "collectWarnings rejects cleanup_command and cwd with control characters" {
    const allocator = std.testing.allocator;
    const warnings = try collectWarnings(allocator,
        \\{
        \\  "runners": {
        \\    "go": { "cmd": "go run $file", "cleanup_command": "rm -f /tmp/out\nrm -rf /", "cwd": "/tmp\r\n" }
        \\  }
        \\}
    );
    defer freeWarnings(allocator, warnings);

    try std.testing.expectEqual(@as(usize, 2), warnings.len);
    try std.testing.expect(std.mem.find(u8, warnings[0], "cleanup_command: contains control characters") != null);
    try std.testing.expect(std.mem.find(u8, warnings[1], "cwd: contains control characters") != null);
}

test "collectWarnings accepts null timeout and rejects non-positive numbers" {
    const allocator = std.testing.allocator;

    {
        const warnings = try collectWarnings(allocator,
            \\{ "timeout": null }
        );
        defer freeWarnings(allocator, warnings);
        try std.testing.expectEqual(@as(usize, 0), warnings.len);
    }

    {
        const warnings = try collectWarnings(allocator,
            \\{ "timeout": 0 }
        );
        defer freeWarnings(allocator, warnings);
        try std.testing.expectEqual(@as(usize, 1), warnings.len);
        try std.testing.expect(std.mem.find(u8, warnings[0], "expected positive number") != null);
    }

    {
        const warnings = try collectWarnings(allocator,
            \\{ "timeout": -5 }
        );
        defer freeWarnings(allocator, warnings);
        try std.testing.expectEqual(@as(usize, 1), warnings.len);
    }
}

test "collectWarnings rejects non-object root" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfigRoot, collectWarnings(allocator, "[1, 2, 3]"));
    try std.testing.expectError(error.InvalidConfigRoot, collectWarnings(allocator, "42"));
    try std.testing.expectError(error.InvalidConfigRoot, collectWarnings(allocator, "\"a string\""));
}
