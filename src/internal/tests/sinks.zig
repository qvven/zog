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

test "flush() is a safe no-op with no file sink" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none }); // no file
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("x", .{});
    log.flush(); // must not crash
}

test "addSink works when called after logging has started" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("before sink", .{}); // not captured
    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());
    log.info("after sink", .{});

    try testing.expectEqual(@as(usize, 1), mem.count());
    try testing.expect(std.mem.indexOf(u8, mem.entries()[0].line, "after sink") != null);
}

test "extra sink drop does not stop later sinks" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var drop: DropSink = .{};
    var mem = MemorySink.init(gpa);
    defer mem.deinit();

    try log.addSink(drop.sink());
    try log.addSink(mem.sink());

    log.info("after drop", .{});

    try testing.expectEqual(@as(usize, 1), drop.count);
    try testing.expectEqual(@as(usize, 1), mem.count());
    try testing.expectEqualStrings("[info] after drop\n", mem.entries()[0].line);
}

test "memory sink: entries() snapshot reflects all lines logged so far" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("first", .{});
    const snap1 = mem.entries();
    try testing.expectEqual(@as(usize, 1), snap1.len);
    try testing.expect(std.mem.indexOf(u8, snap1[0].line, "first") != null);

    // A second entries() call after more logging returns the full set. The
    // prior snapshot must be read before this call; entries() owns a single
    // cached snapshot, replaced here. (Use entriesAlloc for an owned copy.)
    log.info("second", .{});
    const snap2 = mem.entries();
    try testing.expectEqual(@as(usize, 2), snap2.len);
    try testing.expect(std.mem.indexOf(u8, snap2[1].line, "second") != null);
}

test "memory sink: entriesAlloc returns an independently owned snapshot" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("alpha", .{});
    log.info("beta", .{});

    const owned = try mem.entriesAlloc(gpa);
    defer gpa.free(owned);

    try testing.expectEqual(@as(usize, 2), owned.len);
    try testing.expect(std.mem.indexOf(u8, owned[0].line, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, owned[1].line, "beta") != null);
}
