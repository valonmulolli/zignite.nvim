const std = @import("std");

pub const buffer_size = 4096;

pub const Stdin = struct {
    buffer: [buffer_size]u8 = undefined,
    reader: std.Io.File.Reader = undefined,

    pub fn init(self: *Stdin, io_impl: std.Io) void {
        self.reader = std.Io.File.stdin().reader(io_impl, &self.buffer);
    }

    pub fn io(self: *Stdin) *std.Io.Reader {
        return &self.reader.interface;
    }
};

pub const Stdout = struct {
    buffer: [buffer_size]u8 = undefined,
    writer: std.Io.File.Writer = undefined,

    pub fn init(self: *Stdout, io_impl: std.Io) void {
        self.writer = std.Io.File.stdout().writer(io_impl, &self.buffer);
    }

    pub fn io(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};
