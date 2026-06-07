const std = @import("std");
const config_view = @import("../../config/view.zig");

const RunnerSpec = struct {
    filetype: []const u8,
    command: []const u8,
    cleanup_command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

const temp_binary_cleanup = "rm /tmp/$fileNameWithoutExt";

fn tempBinarySpec(comptime filetype: []const u8, comptime compiler_prefix: []const u8) RunnerSpec {
    return .{
        .filetype = filetype,
        .command = std.fmt.comptimePrint(
            "{s} $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt",
            .{compiler_prefix},
        ),
        .cleanup_command = temp_binary_cleanup,
    };
}

const builtin_specs = [_]RunnerSpec{
    tempBinarySpec("c", "gcc"),
    tempBinarySpec("cpp", "c++ -pipe"),
    tempBinarySpec("rust", "rustc"),
    .{ .filetype = "go", .command = "go run $file" },
    .{ .filetype = "zig", .command = "zig run $file" },
    .{
        .filetype = "java",
        .command = "javac $file && java -cp $dir $fileNameWithoutExt",
        .cleanup_command = "rm -f $dir/$fileNameWithoutExt.class",
    },
    .{
        .filetype = "kotlin",
        .command = "kotlinc $file -include-runtime -d /tmp/$fileNameWithoutExt.jar && java -jar /tmp/$fileNameWithoutExt.jar",
        .cleanup_command = "rm /tmp/$fileNameWithoutExt.jar",
    },
    .{ .filetype = "python", .command = "python3 -u $file" },
    .{ .filetype = "javascript", .command = "node $file" },
    .{ .filetype = "typescript", .command = "bun $file" },
    .{ .filetype = "lua", .command = "lua $file" },
    .{ .filetype = "ruby", .command = "ruby $file" },
    .{ .filetype = "php", .command = "php $file" },
    .{ .filetype = "perl", .command = "perl $file" },
    .{ .filetype = "r", .command = "Rscript $file" },
    .{ .filetype = "julia", .command = "julia $file" },
    .{ .filetype = "sh", .command = "bash $file" },
    .{ .filetype = "zsh", .command = "zsh $file" },
    .{ .filetype = "html", .command = "xdg-open $file" },
    .{ .filetype = "dart", .command = "dart run $file" },
    .{ .filetype = "swift", .command = "swift $file" },
    .{ .filetype = "elixir", .command = "elixir $file" },
    .{
        .filetype = "haskell",
        .command = "ghc -o /tmp/$fileNameWithoutExt $file && /tmp/$fileNameWithoutExt",
        .cleanup_command = temp_binary_cleanup,
    },
    .{ .filetype = "odin", .command = "odin run $file -file" },
    tempBinarySpec("fortran", "gfortran"),
};

fn makeRunner(allocator: std.mem.Allocator, spec: RunnerSpec) !config_view.RunnerConfig {
    var runner = config_view.RunnerConfig{
        .command = try allocator.dupe(u8, spec.command),
    };
    errdefer runner.deinit(allocator);

    if (spec.cleanup_command) |cleanup| {
        runner.cleanup_command = try allocator.dupe(u8, cleanup);
    }
    if (spec.cwd) |dir| {
        runner.cwd = try allocator.dupe(u8, dir);
    }

    return runner;
}

fn findSpec(filetype: []const u8) ?RunnerSpec {
    for (builtin_specs) |spec| {
        if (std.mem.eql(u8, spec.filetype, filetype)) return spec;
    }
    return null;
}

pub fn loadRunnerConfig(allocator: std.mem.Allocator, filetype: []const u8) !?config_view.RunnerConfig {
    const spec = findSpec(filetype) orelse return null;
    return try makeRunner(allocator, spec);
}

test "loadRunnerConfig returns builtin runner config" {
    var runner = (try loadRunnerConfig(std.testing.allocator, "go")).?;
    defer runner.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("go run $file", runner.command.?);
    try std.testing.expect(runner.cleanup_command == null);
    try std.testing.expect(runner.cwd == null);
}

test "loadRunnerConfig returns builtin cleanup command when present" {
    var runner = (try loadRunnerConfig(std.testing.allocator, "cpp")).?;
    defer runner.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("c++ -pipe $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt", runner.command.?);
    try std.testing.expectEqualStrings("rm /tmp/$fileNameWithoutExt", runner.cleanup_command.?);
}

test "loadRunnerConfig returns null for unknown filetype" {
    try std.testing.expect((try loadRunnerConfig(std.testing.allocator, "unknown")) == null);
}

test "loadRunnerConfig returns zig and rust builtin commands" {
    {
        var runner = (try loadRunnerConfig(std.testing.allocator, "zig")).?;
        defer runner.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("zig run $file", runner.command.?);
    }
    {
        var runner = (try loadRunnerConfig(std.testing.allocator, "rust")).?;
        defer runner.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("rustc $file -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt", runner.command.?);
        try std.testing.expectEqualStrings("rm /tmp/$fileNameWithoutExt", runner.cleanup_command.?);
    }
}

test "loadRunnerConfig returns java cleanup with $dir placeholder" {
    var runner = (try loadRunnerConfig(std.testing.allocator, "java")).?;
    defer runner.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("javac $file && java -cp $dir $fileNameWithoutExt", runner.command.?);
    try std.testing.expectEqualStrings("rm -f $dir/$fileNameWithoutExt.class", runner.cleanup_command.?);
}

test "loadRunnerConfig returns haskell with /tmp binary cleanup" {
    var runner = (try loadRunnerConfig(std.testing.allocator, "haskell")).?;
    defer runner.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ghc -o /tmp/$fileNameWithoutExt $file && /tmp/$fileNameWithoutExt", runner.command.?);
    try std.testing.expectEqualStrings("rm /tmp/$fileNameWithoutExt", runner.cleanup_command.?);
}
