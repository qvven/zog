//! Size-based file rotation. Build with `zig build examples`.

const std = @import("std");
const zog = @import("zog");

const Logger = zog.make(.{
    .stderr = false,
    .timestamp = .none,
    .file_path = "zog-rotation-example.log",
    .file_rotation = .{ .size = .{ .max_bytes = 96 } },
});

pub fn main(init: std.process.Init) !void {
    var log = try Logger.open(init.gpa, init.io);
    defer log.close(init.io);

    log.info("first event with enough bytes to cross the configured cap", .{});
    log.info("second event starts in the fresh active file", .{});
}
