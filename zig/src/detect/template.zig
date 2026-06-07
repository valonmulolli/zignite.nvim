const std = @import("std");
const types = @import("types.zig");

const Tool = types.Tool;
const BUILD_ARG_PLACEHOLDER = "$zignite_args";

pub fn buildDetectCommandRecords(allocator: std.mem.Allocator, tool: Tool, names: []const []const u8) ![][]u8 {
    var commands: std.ArrayList([]u8) = .empty;
    errdefer {
        for (commands.items) |command| allocator.free(command);
        commands.deinit(allocator);
    }

    for (names) |name| {
        const template = try detectCommandTemplate(allocator, tool, name);
        defer allocator.free(template);
        const record = try std.fmt.allocPrint(allocator, "{s}\t{s}", .{ name, template });
        commands.append(allocator, record) catch |err| {
            allocator.free(record);
            return err;
        };
    }

    return try commands.toOwnedSlice(allocator);
}

fn detectCommandTemplate(allocator: std.mem.Allocator, tool: Tool, name: []const u8) ![]u8 {
    if (tool == .zig) {
        if (std.mem.eql(u8, name, "ast-check")) return allocator.dupe(u8, "zig ast-check $file");
        if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "zig build");
        if (std.mem.eql(u8, name, "build-exe")) return allocator.dupe(u8, "zig build-exe $file");
        if (std.mem.eql(u8, name, "build-lib")) return allocator.dupe(u8, "zig build-lib $file");
        if (std.mem.eql(u8, name, "build-obj")) return allocator.dupe(u8, "zig build-obj $file");
        if (std.mem.eql(u8, name, "env")) return allocator.dupe(u8, "zig env");
        if (std.mem.eql(u8, name, "fetch")) return std.fmt.allocPrint(allocator, "zig fetch {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "fmt")) return allocator.dupe(u8, "zig fmt $file");
        if (std.mem.eql(u8, name, "help")) return allocator.dupe(u8, "zig help");
        if (std.mem.eql(u8, name, "init")) return allocator.dupe(u8, "zig init");
        if (std.mem.eql(u8, name, "libc")) return allocator.dupe(u8, "zig libc");
        if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "zig run $file");
        if (std.mem.eql(u8, name, "std")) return allocator.dupe(u8, "zig std");
        if (std.mem.eql(u8, name, "targets")) return allocator.dupe(u8, "zig targets");
        if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "zig test $file");
        if (std.mem.eql(u8, name, "test-obj")) return allocator.dupe(u8, "zig test-obj $file");
        if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "zig version");
        if (std.mem.eql(u8, name, "zen")) return allocator.dupe(u8, "zig zen");
        return std.fmt.allocPrint(allocator, "zig {s}", .{name});
    }

    if (tool == .go) {
        if (std.mem.eql(u8, name, "bug")) return allocator.dupe(u8, "go bug");
        if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "go build");
        if (std.mem.eql(u8, name, "clean")) return allocator.dupe(u8, "go clean");
        if (std.mem.eql(u8, name, "doc")) return allocator.dupe(u8, "go doc");
        if (std.mem.eql(u8, name, "env")) return allocator.dupe(u8, "go env");
        if (std.mem.eql(u8, name, "fix")) return allocator.dupe(u8, "go fix ./...");
        if (std.mem.eql(u8, name, "fmt")) return allocator.dupe(u8, "go fmt ./...");
        if (std.mem.eql(u8, name, "generate")) return allocator.dupe(u8, "go generate ./...");
        if (std.mem.eql(u8, name, "get")) return allocator.dupe(u8, "go get ./...");
        if (std.mem.eql(u8, name, "install")) return allocator.dupe(u8, "go install ./...");
        if (std.mem.eql(u8, name, "list")) return allocator.dupe(u8, "go list ./...");
        if (std.mem.eql(u8, name, "mod")) return allocator.dupe(u8, "go mod tidy");
        if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "go run .");
        if (std.mem.eql(u8, name, "telemetry")) return allocator.dupe(u8, "go telemetry");
        if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "go test ./...");
        if (std.mem.eql(u8, name, "tool")) return allocator.dupe(u8, "go tool");
        if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "go version");
        if (std.mem.eql(u8, name, "vet")) return allocator.dupe(u8, "go vet ./...");
        if (std.mem.eql(u8, name, "work")) return allocator.dupe(u8, "go work sync");
        return std.fmt.allocPrint(allocator, "go {s}", .{name});
    }

    if (tool == .cargo) {
        if (std.mem.eql(u8, name, "add")) return std.fmt.allocPrint(allocator, "cargo add {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "bench")) return allocator.dupe(u8, "cargo bench");
        if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "cargo build");
        if (std.mem.eql(u8, name, "check")) return allocator.dupe(u8, "cargo check");
        if (std.mem.eql(u8, name, "clean")) return allocator.dupe(u8, "cargo clean");
        if (std.mem.eql(u8, name, "clippy")) return allocator.dupe(u8, "cargo clippy");
        if (std.mem.eql(u8, name, "doc")) return allocator.dupe(u8, "cargo doc --open");
        if (std.mem.eql(u8, name, "fetch")) return allocator.dupe(u8, "cargo fetch");
        if (std.mem.eql(u8, name, "fix")) return allocator.dupe(u8, "cargo fix");
        if (std.mem.eql(u8, name, "generate-lockfile")) return allocator.dupe(u8, "cargo generate-lockfile");
        if (std.mem.eql(u8, name, "init")) return allocator.dupe(u8, "cargo init");
        if (std.mem.eql(u8, name, "install")) return std.fmt.allocPrint(allocator, "cargo install {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "locate-project")) return allocator.dupe(u8, "cargo locate-project");
        if (std.mem.eql(u8, name, "login")) return allocator.dupe(u8, "cargo login");
        if (std.mem.eql(u8, name, "logout")) return allocator.dupe(u8, "cargo logout");
        if (std.mem.eql(u8, name, "metadata")) return allocator.dupe(u8, "cargo metadata");
        if (std.mem.eql(u8, name, "new")) return std.fmt.allocPrint(allocator, "cargo new {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "owner")) return std.fmt.allocPrint(allocator, "cargo owner {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "package")) return allocator.dupe(u8, "cargo package");
        if (std.mem.eql(u8, name, "publish")) return allocator.dupe(u8, "cargo publish");
        if (std.mem.eql(u8, name, "remove")) return std.fmt.allocPrint(allocator, "cargo remove {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "cargo run");
        if (std.mem.eql(u8, name, "rustc")) return allocator.dupe(u8, "cargo rustc");
        if (std.mem.eql(u8, name, "rustdoc")) return allocator.dupe(u8, "cargo rustdoc");
        if (std.mem.eql(u8, name, "search")) return std.fmt.allocPrint(allocator, "cargo search {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "cargo test");
        if (std.mem.eql(u8, name, "tree")) return allocator.dupe(u8, "cargo tree");
        if (std.mem.eql(u8, name, "uninstall")) return std.fmt.allocPrint(allocator, "cargo uninstall {s}", .{BUILD_ARG_PLACEHOLDER});
        if (std.mem.eql(u8, name, "update")) return allocator.dupe(u8, "cargo update");
        if (std.mem.eql(u8, name, "vendor")) return allocator.dupe(u8, "cargo vendor");
        if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "cargo version");
        return std.fmt.allocPrint(allocator, "cargo {s}", .{name});
    }

    if (std.mem.eql(u8, name, "build")) return allocator.dupe(u8, "odin build .");
    if (std.mem.eql(u8, name, "check")) return allocator.dupe(u8, "odin check .");
    if (std.mem.eql(u8, name, "doc")) return allocator.dupe(u8, "odin doc .");
    if (std.mem.eql(u8, name, "query")) return std.fmt.allocPrint(allocator, "odin query {s}", .{BUILD_ARG_PLACEHOLDER});
    if (std.mem.eql(u8, name, "run")) return allocator.dupe(u8, "odin run .");
    if (std.mem.eql(u8, name, "test")) return allocator.dupe(u8, "odin test .");
    if (std.mem.eql(u8, name, "version")) return allocator.dupe(u8, "odin version");
    return std.fmt.allocPrint(allocator, "odin {s}", .{name});
}

test "detect command records include rendered templates" {
    const allocator = std.testing.allocator;
    const output_names = [_][]const u8{ "metadata", "run" };
    const commands = try buildDetectCommandRecords(allocator, .cargo, &output_names);
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("metadata\tcargo metadata", commands[0]);
    try std.testing.expectEqualStrings("run\tcargo run", commands[1]);
}

test "detect command records use $file placeholder for zig run/test/fmt" {
    const allocator = std.testing.allocator;
    const commands = try buildDetectCommandRecords(allocator, .zig, &.{ "run", "test", "fmt" });
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqualStrings("run\tzig run $file", commands[0]);
    try std.testing.expectEqualStrings("test\tzig test $file", commands[1]);
    try std.testing.expectEqualStrings("fmt\tzig fmt $file", commands[2]);
}

test "detect command records fall through to default for unknown names" {
    const allocator = std.testing.allocator;
    const commands = try buildDetectCommandRecords(allocator, .zig, &.{"custom"});
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqualStrings("custom\tzig custom", commands[0]);
}

test "detect command records use $zignite_args placeholder for argument-taking cargo subcommands" {
    const allocator = std.testing.allocator;
    const commands = try buildDetectCommandRecords(allocator, .cargo, &.{ "add", "search" });
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqualStrings("add\tcargo add $zignite_args", commands[0]);
    try std.testing.expectEqualStrings("search\tcargo search $zignite_args", commands[1]);
}

test "detect command records map odin subcommands" {
    const allocator = std.testing.allocator;
    const commands = try buildDetectCommandRecords(allocator, .odin, &.{ "build", "test" });
    defer types.freeOwnedCommandList(allocator, commands);

    try std.testing.expectEqualStrings("build\todin build .", commands[0]);
    try std.testing.expectEqualStrings("test\todin test .", commands[1]);
}
