const std = @import("std");
const zog = @import("zog");

const Scope = enum {
    default,
    server,
    admin,

    pub fn minLevel(comptime s: @This()) zog.Level {
        return switch (s) {
            .admin => .debug,
            else => .info,
        };
    }
};

const Logger = zog.make(.{
    .Scope = Scope,
    .timestamp = .none,
});

pub fn main(init: std.process.Init) !void {
    var log = try Logger.open(init.gpa, init.io);
    defer log.close(init.io);

    const server = log.scope(.server);
    const admin = log.scope(.admin);

    server.debug("cache warm", .{});
    server.info("request handled", .{ .status = @as(u16, 200) });
    admin.debug("loaded settings panel", .{});
}
