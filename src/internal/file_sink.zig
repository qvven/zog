const std = @import("std");
const Io = std.Io;
const rotation_internal = @import("rotation.zig");

pub fn Make(comptime cfg: anytype) type {
    return struct {
        const Self = @This();

        file: ?Io.File = null,
        writer: Io.File.Writer = undefined,
        opened: bool = false,
        bytes: u64 = 0,
        gpa: std.mem.Allocator,
        io: Io,

        pub fn open(gpa: std.mem.Allocator, io: Io) !Self {
            var self: Self = .{
                .gpa = gpa,
                .io = io,
            };
            errdefer self.close();

            if (comptime cfg.file_path) |path| {
                try ensureParentDir(io, path);
                const f = try Io.Dir.cwd().createFile(io, path, .{
                    .truncate = false,
                    .read = true,
                });
                var file_owned = true;
                errdefer if (file_owned) f.close(io);

                const file_buf = try gpa.alloc(u8, cfg.file_buf_bytes);
                self.file = f;
                file_owned = false;
                self.writer = f.writer(io, file_buf);
                self.opened = true;

                const end = f.length(io) catch 0;
                self.writer.seekTo(end) catch {};
                self.bytes = end;
            }

            return self;
        }

        pub fn close(self: *Self) void {
            if (self.file) |f| {
                self.writer.interface.flush() catch {};
                f.close(self.io);
                self.file = null;
            }
            if (self.opened) {
                self.gpa.free(self.writer.interface.buffer);
                self.opened = false;
            }
        }

        pub fn flush(self: *Self) !void {
            if (self.file != null) {
                try self.writer.interface.flush();
            }
        }

        pub fn writeLine(self: *Self, line: []const u8, do_flush: bool) !void {
            if (self.file == null) return;

            const w = &self.writer.interface;
            try w.writeAll(line);
            if (do_flush) try w.flush();

            self.bytes += line.len;
            switch (comptime cfg.file_rotation) {
                .none => {},
                .size => |rotation| {
                    if (self.bytes >= rotation.max_bytes) {
                        try self.rotate();
                    }
                },
            }
        }

        fn rotate(self: *Self) !void {
            const path = comptime cfg.file_path orelse unreachable;
            try self.writer.interface.flush();
            if (self.file) |f| {
                f.close(self.io);
                self.file = null;
            }
            errdefer self.reopen(false) catch {};

            var scratch: [rotation_internal.timestampedScratchLen(path.len)]u8 = undefined;
            const now = Io.Clock.now(.real, self.io).toMilliseconds();
            try rotation_internal.rotateTimestamped(self.io, Io.Dir.cwd(), path, now, &scratch);
            try self.reopen(true);
        }

        fn reopen(self: *Self, comptime truncate: bool) !void {
            const path = comptime cfg.file_path orelse unreachable;
            try ensureParentDir(self.io, path);
            const f = try Io.Dir.cwd().createFile(self.io, path, .{
                .truncate = truncate,
                .read = true,
            });
            errdefer f.close(self.io);

            self.file = f;
            self.writer = f.writer(self.io, self.writer.interface.buffer);
            self.bytes = if (truncate) 0 else f.length(self.io) catch 0;
            if (!truncate) self.writer.seekTo(self.bytes) catch {};
        }
    };
}

fn ensureParentDir(io: Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try Io.Dir.cwd().createDirPath(io, parent);
}
