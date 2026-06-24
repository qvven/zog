const h = @import("helpers.zig");

const std = h.std;
const testing = h.testing;
const zog = h.zog;
const Level = h.Level;
const MemorySink = h.MemorySink;
const make = h.make;
const time_internal = h.time_internal;
const rotation_internal = h.rotation_internal;

const parseJsonLine = h.parseJsonLine;
const expectJsonString = h.expectJsonString;
const expectJsonInteger = h.expectJsonInteger;
const expectJsonBool = h.expectJsonBool;
const expectJsonNull = h.expectJsonNull;
const openCloseNoFile = h.openCloseNoFile;
const DropSink = h.DropSink;
const deleteLogFiles = h.deleteLogFiles;
const deleteLogFamily = h.deleteLogFamily;
const writeWholeFile = h.writeWholeFile;
const findSingleArchive = h.findSingleArchive;
const readLogFileAlloc = h.readLogFileAlloc;
const fileSize = h.fileSize;
const openCloseWithFile = h.openCloseWithFile;

test "kv: scoped logger with fields still obeys level filtering" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Scope = enum {
        default,
        worker,
        pub fn minLevel(comptime s: @This()) Level {
            return switch (s) {
                .worker => .warn,
                else => .info,
            };
        }
    };

    const Logger = make(.{ .stderr = false, .timestamp = .none, .Scope = Scope });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const w = log.scope(.worker);
    w.info("task done", .{ .id = @as(u32, 1) });
    w.warn("slow task", .{ .id = @as(u32, 2), .ms = @as(u32, 1500) });

    try testing.expectEqual(@as(usize, 1), mem.count());
    try testing.expectEqualStrings(
        "[warn] [worker] slow task id=2 ms=1500\n",
        mem.entries()[0].line,
    );
}

test "with: text logger prepends context fields before user fields" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const ctx = log.with(.{ .request_id = "abc-123", .user = "ada" });
    ctx.info("starting", .{});
    ctx.warn("slow query", .{ .ms = @as(u32, 230) });

    try testing.expectEqualStrings(
        "[info] starting request_id=abc-123 user=ada\n",
        mem.entries()[0].line,
    );
    try testing.expectEqualStrings(
        "[warn] slow query request_id=abc-123 user=ada ms=230\n",
        mem.entries()[1].line,
    );
}

test "with: json logger emits context fields after msg, before user fields" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const ctx = log.with(.{ .request_id = "abc-123" });
    ctx.info("login", .{ .user = "ada" });

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"msg\":\"login\",\"request_id\":\"abc-123\",\"user\":\"ada\"}\n",
        mem.entries()[0].line,
    );
}

test "with: chained .with(...).with(...) merges prefixes in order" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const a = log.with(.{ .request_id = "rid" });
    const b = a.with(.{ .user = "ada" });
    b.info("ok", .{});

    try testing.expectEqualStrings(
        "[info] ok request_id=rid user=ada\n",
        mem.entries()[0].line,
    );
}

test "with: composes with at(@src()) and scope()" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Scope = enum { default, http };
    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .source = .file_line,
        .Scope = Scope,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const loc = @src();
    log.scope(.http).with(.{ .request_id = "rid" }).at(loc).info("hit", .{});
    log.with(.{ .request_id = "rid2" }).at(loc).warn("slow", .{ .ms = @as(u32, 5) });

    try testing.expect(std.mem.indexOf(u8, mem.entries()[0].line, "[info] [http]") != null);
    try testing.expect(std.mem.indexOf(u8, mem.entries()[0].line, "request_id=rid") != null);
    try testing.expect(std.mem.indexOf(u8, mem.entries()[0].line, "hit") != null);

    var loc_marker: [32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&loc_marker, ":{d} ", .{loc.line});
    try testing.expect(std.mem.indexOf(u8, mem.entries()[0].line, marker) != null);

    try testing.expect(std.mem.endsWith(u8, mem.entries()[1].line, "ms=5\n"));
    try testing.expect(std.mem.indexOf(u8, mem.entries()[1].line, "request_id=rid2") != null);
}
