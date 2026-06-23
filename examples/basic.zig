const std = @import("std");
const zog = @import("zog");

const Logger = zog.make(.{
    .timestamp = .none,
});

pub fn main(init: std.process.Init) !void {
    var log = try Logger.open(init.gpa, init.io);
    defer log.close(init.io);

    log.info("ready", .{});
    log.warn("disk {d}% full", .{@as(u8, 92)});
}
