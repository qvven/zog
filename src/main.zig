//! Internal demo. Run with `zig build run`.

const std = @import("std");
const zog = @import("zog");

const Logger = zog.make(.{
    .stderr = true,
    .timestamp = .iso8601_utc,
    .format = .text,
});

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("hello {s}", .{"world"});
    log.warn("warning {s}", .{"warning"});
    log.err("error {s}", .{"error"});
    log.info("user login", .{ .user = "ada", .uid = @as(u32, 42) });
}
