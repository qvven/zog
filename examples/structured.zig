//! Structured key/value logging: enum and optional field values, in JSON.
//! Build with `zig build examples`.

const std = @import("std");
const zog = @import("zog");

const Method = enum { get, post, delete };

const Logger = zog.make(.{
    .format = .json,
    .timestamp = .none,
});

pub fn main(init: std.process.Init) !void {
    var log = try Logger.open(init.gpa, init.io);
    defer log.close(init.io);

    const user_id: ?u32 = 42;
    const trace_id: ?[]const u8 = null;

    // Enums render by tag name; present optionals unwrap; null optionals
    // become a real JSON null.
    log.info("request", .{
        .method = Method.post,
        .path = "/login",
        .status = @as(u16, 200),
        .user_id = user_id, // -> "user_id":42
        .trace_id = trace_id, // -> "trace_id":null
    });
}
