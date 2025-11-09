// const std = @import("std");

// pub fn main() !void {
//     // Use GeneralPurposeAllocator for better memory management
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     // --- Argument Parsing ---
//     const args = try std.process.argsAlloc(allocator);
//     defer allocator.free(args);
//     const argv = args[1..];

//     // --- Input Validation ---
//     if (argv.len == 0) {
//         std.log.err("Usage: zignite <command> [args...]", .{});
//         std.log.err("Error: No command provided", .{});
//         std.process.exit(1);
//     }

//     // --- Command Validation ---
//     const command = argv[0];

//     // Check if command exists and is accessible
//     if (std.fs.path.isAbsolute(command)) {
//         // Check if the file exists and is accessible
//         std.fs.accessAbsolute(command, .{}) catch {
//             std.log.err("Error: Command not found or not accessible: '{s}'", .{command});
//             std.process.exit(127);
//         };
//     } else {
//         // Search in PATH
//         const path_env = std.posix.getenv("PATH") orelse {
//             std.log.err("Error: PATH environment variable not found", .{});
//             std.process.exit(127);
//         };

//         var found = false;
//         var path_iter = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);

//         while (path_iter.next()) |search_path| {
//             const full_cmd = try std.fs.path.join(allocator, &[_][]const u8{ search_path, command });
//             defer allocator.free(full_cmd);

//             std.fs.accessAbsolute(full_cmd, .{}) catch continue;
//             found = true;
//             break;
//         }

//         if (!found) {
//             std.log.err("Error: Command '{s}' not found in PATH", .{command});
//             std.process.exit(127);
//         }
//     }

//     // --- Child Process Execution ---
//     var child = std.process.Child.init(argv, allocator);

//     // Inherit stdin/stdout/stderr from parent process
//     child.stdin_behavior = .Inherit;
//     child.stdout_behavior = .Inherit;
//     child.stderr_behavior = .Inherit;

//     const term = child.spawnAndWait() catch |err| {
//         std.log.err("Failed to spawn child process: {}", .{err});
//         std.process.exit(1);
//     };

//     // --- Exit with proper code ---
//     const exit_code: u8 = switch (term) {
//         .Exited => |code| blk: {
//             break :blk if (code > 255) 255 else @as(u8, @intCast(code));
//         },
//         .Signal => |sig| blk: {
//             const code = 128 + sig;
//             break :blk if (code > 255) 255 else @as(u8, @intCast(code));
//         },
//         .Stopped => |sig| blk: {
//             const code = 128 + sig;
//             break :blk if (code > 255) 255 else @as(u8, @intCast(code));
//         },
//         .Unknown => |status| blk: {
//             break :blk if (status > 255) 255 else @as(u8, @intCast(status));
//         },
//     };

//     std.process.exit(exit_code);
// }

const std = @import("std");

pub fn main() !void {
    // Use GeneralPurposeAllocator for better memory management
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- Argument Parsing ---
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const argv = args[1..];

    // --- Input Validation ---
    if (argv.len == 0) {
        std.log.err("Usage: zignite <full command string>", .{});
        std.log.err("Error: No command provided", .{});
        std.process.exit(1);
    }

    // Get the shell to use
    const shell = std.posix.getenv("SHELL") orelse "/bin/sh";

    // Use the first argument as the complete command string
    const full_command = argv[0];

    // Execute through shell with -c flag
    const shell_args = [_][]const u8{ shell, "-c", full_command };

    // --- Child Process Execution ---
    var child = std.process.Child.init(&shell_args, allocator);

    // Inherit stdin/stdout/stderr from parent process
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.log.err("Failed to spawn child process: {}", .{err});
        std.process.exit(1);
    };

    // --- Exit with proper code ---
    const exit_code: u8 = switch (term) {
        .Exited => |code| blk: {
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Signal => |sig| blk: {
            const code = 128 + sig;
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Stopped => |sig| blk: {
            const code = 128 + sig;
            break :blk if (code > 255) 255 else @as(u8, @intCast(code));
        },
        .Unknown => |status| blk: {
            break :blk if (status > 255) 255 else @as(u8, @intCast(status));
        },
    };

    std.process.exit(exit_code);
}
