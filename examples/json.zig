const std = @import("std");
const zog = @import("zog");

const Logger = zog.make(.{
    .format = .json,
    .timestamp = .none,
});

pub fn main(init: std.process.Init) !void {
    var log = try Logger.open(init.gpa, init.io);
    defer log.close(init.io);

    log.info("user login", .{
        .user = "ada",
        .uid = @as(u32, 42),
        .ok = true,
    });
}
