const std = @import("std");

pub fn buildMarkerSignatureAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    markers: []const []const u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return buildMarkerSignatureAllocWithIO(threaded.io(), allocator, root, markers);
}

pub fn buildMarkerSignatureAllocWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    markers: []const []const u8,
) ![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    errdefer signature.deinit(allocator);

    for (markers, 0..) |marker, index| {
        if (index > 0) try signature.append(allocator, '|');
        try signature.appendSlice(allocator, marker);
        try signature.append(allocator, ':');

        const file_path = try std.fs.path.join(allocator, &.{ root, marker });
        defer allocator.free(file_path);

        const mtime_key = try fileMtimeKeyAllocWithIO(io, allocator, file_path);
        defer if (mtime_key) |key| allocator.free(key);

        if (mtime_key) |key| {
            try signature.appendSlice(allocator, key);
        } else {
            try signature.appendSlice(allocator, "missing");
        }
    }

    return try signature.toOwnedSlice(allocator);
}

pub fn appendSignatureFile(
    allocator: std.mem.Allocator,
    signature: *std.ArrayList(u8),
    path: []const u8,
) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return appendSignatureFileWithIO(threaded.io(), allocator, signature, path);
}

pub fn appendSignatureFileWithIO(
    io: std.Io,
    allocator: std.mem.Allocator,
    signature: *std.ArrayList(u8),
    path: []const u8,
) !void {
    try signature.append(allocator, '|');
    try signature.appendSlice(allocator, path);
    try signature.append(allocator, ':');

    const mtime_key = try fileMtimeKeyAllocWithIO(io, allocator, path);
    defer if (mtime_key) |key| allocator.free(key);
    if (mtime_key) |key| {
        try signature.appendSlice(allocator, key);
    } else {
        try signature.appendSlice(allocator, "missing");
    }
}

pub fn fileMtimeKeyAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return fileMtimeKeyAllocWithIO(threaded.io(), allocator, path);
}

pub fn fileMtimeKeyAllocWithIO(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = try file.stat(io);
    return try std.fmt.allocPrint(allocator, "{d}:{d}", .{ stat.size, stat.mtime });
}

test "buildMarkerSignatureAlloc marks missing files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);

    const signature = try buildMarkerSignatureAllocWithIO(std.testing.io, allocator, root, &.{ "present.txt", "missing.txt" });
    defer allocator.free(signature);

    try std.testing.expect(std.mem.find(u8, signature, "present.txt:missing") != null);
    try std.testing.expect(std.mem.find(u8, signature, "missing.txt:missing") != null);
}
