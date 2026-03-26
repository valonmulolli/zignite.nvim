const std = @import("std");

pub const buffer_size = 4096;

pub const Stdin = struct {
    buffer: [buffer_size]u8 = undefined,
    reader: std.fs.File.Reader = undefined,

    pub fn init(self: *Stdin) void {
        self.reader = std.fs.File.stdin().reader(&self.buffer);
    }

    pub fn io(self: *Stdin) *std.Io.Reader {
        return &self.reader.interface;
    }
};

pub const Stdout = struct {
    buffer: [buffer_size]u8 = undefined,
    writer: std.fs.File.Writer = undefined,

    pub fn init(self: *Stdout) void {
        self.writer = std.fs.File.stdout().writer(&self.buffer);
    }

    pub fn io(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};

