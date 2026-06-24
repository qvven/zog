const std = @import("std");
const Io = std.Io;

const ANSI_RESET = "\x1b[0m";

fn ansi(level: anytype) []const u8 {
    return switch (level) {
        .debug => "\x1b[90m", // dim gray
        .info => "\x1b[32m", // green
        .warn => "\x1b[33m", // yellow
        .err => "\x1b[31m", // red
    };
}

pub fn Make(comptime cfg: anytype) type {
    return struct {
        const Self = @This();

        file: Io.File = undefined,
        writer: Io.File.Writer = undefined,
        opened: bool = false,
        colorize: bool = false,
        gpa: std.mem.Allocator,

        pub fn open(gpa: std.mem.Allocator, io: Io) !Self {
            var self: Self = .{
                .gpa = gpa,
            };
            errdefer self.close();

            const buf_len = cfg.max_line_bytes + 16;
            const buf = try gpa.alloc(u8, buf_len);
            self.file = Io.File.stderr();
            self.writer = self.file.writer(io, buf);
            self.opened = true;

            self.file.enableAnsiEscapeCodes(io) catch {};
            self.colorize = self.file.supportsAnsiEscapeCodes(io) catch false;

            return self;
        }

        pub fn close(self: *Self) void {
            if (self.opened) {
                self.writer.interface.flush() catch {};
                self.gpa.free(self.writer.interface.buffer);
                self.opened = false;
            }
        }

        pub fn flush(self: *Self) void {
            if (self.opened) self.writer.interface.flush() catch {};
        }

        pub fn writeLine(self: *Self, level: anytype, line: []const u8) void {
            if (!self.opened) return;

            const w = &self.writer.interface;
            if (self.colorize) {
                w.writeAll(ansi(level)) catch {};
                w.writeAll(line) catch {};
                w.writeAll(ANSI_RESET) catch {};
            } else {
                w.writeAll(line) catch {};
            }
            w.flush() catch {};
        }

        pub fn writePlain(self: *Self, bytes: []const u8) void {
            if (!self.opened) return;

            const w = &self.writer.interface;
            w.writeAll(bytes) catch {};
            w.flush() catch {};
        }
    };
}
