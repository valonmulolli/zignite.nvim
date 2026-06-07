const std = @import("std");

pub const Options = struct {
    max_lines: usize = 1000,
    max_bytes: usize = 262_144,
    strip_ansi: bool = true,
    strip_max_lines: usize = 400,
    parse_diagnostics: bool = true,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--quickfix")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--max-lines=")) {
            options.max_lines = try parseNonZeroInt(arg["--max-lines=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--max-bytes=")) {
            options.max_bytes = try parseNonZeroInt(arg["--max-bytes=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--strip-ansi=")) {
            options.strip_ansi = try parseBool(arg["--strip-ansi=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--strip-max-lines=")) {
            options.strip_max_lines = try parseNonZeroInt(arg["--strip-max-lines=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--parse-diagnostics=")) {
            options.parse_diagnostics = try parseBool(arg["--parse-diagnostics=".len..]);
        } else {
            return error.InvalidQuickfixFlag;
        }
    }

    return options;
}

pub fn parseNonZeroInt(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    return if (parsed == 0) 1 else parsed;
}

pub fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) return false;
    return error.InvalidBoolean;
}

test "parseArgs returns defaults when only --quickfix is supplied" {
    const options = try parseArgs(&.{"--quickfix"});
    try std.testing.expectEqual(@as(usize, 1000), options.max_lines);
    try std.testing.expectEqual(@as(usize, 262_144), options.max_bytes);
    try std.testing.expect(options.strip_ansi);
    try std.testing.expectEqual(@as(usize, 400), options.strip_max_lines);
    try std.testing.expect(options.parse_diagnostics);
}

test "parseArgs parses every flag and overwrites defaults" {
    const options = try parseArgs(&.{
        "--max-lines=50",
        "--max-bytes=2048",
        "--strip-ansi=false",
        "--strip-max-lines=10",
        "--parse-diagnostics=true",
    });
    try std.testing.expectEqual(@as(usize, 50), options.max_lines);
    try std.testing.expectEqual(@as(usize, 2048), options.max_bytes);
    try std.testing.expect(!options.strip_ansi);
    try std.testing.expectEqual(@as(usize, 10), options.strip_max_lines);
    try std.testing.expect(options.parse_diagnostics);
}

test "parseArgs rejects unknown flags" {
    try std.testing.expectError(error.InvalidQuickfixFlag, parseArgs(&.{"--unknown"}));
    try std.testing.expectError(error.InvalidQuickfixFlag, parseArgs(&.{ "--quickfix", "--bogus=1" }));
}

test "parseNonZeroInt coerces 0 to 1 and accepts non-zero" {
    try std.testing.expectEqual(@as(usize, 1), try parseNonZeroInt("0"));
    try std.testing.expectEqual(@as(usize, 42), try parseNonZeroInt("42"));
}

test "parseNonZeroInt rejects non-numeric input" {
    try std.testing.expectError(error.InvalidCharacter, parseNonZeroInt("abc"));
    try std.testing.expectError(error.InvalidCharacter, parseNonZeroInt(""));
}

test "parseBool accepts 0/1 and true/false (case-insensitive)" {
    try std.testing.expect(try parseBool("1"));
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(try parseBool("TRUE"));
    try std.testing.expect(try parseBool("True"));
    try std.testing.expect(!try parseBool("0"));
    try std.testing.expect(!try parseBool("false"));
    try std.testing.expect(!try parseBool("FALSE"));
}

test "parseBool rejects ambiguous strings" {
    try std.testing.expectError(error.InvalidBoolean, parseBool("yes"));
    try std.testing.expectError(error.InvalidBoolean, parseBool(""));
    try std.testing.expectError(error.InvalidBoolean, parseBool("2"));
}
