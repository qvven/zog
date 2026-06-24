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

test "flush policy: every_line makes file writes visible immediately" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "flush_every.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{ .stderr = false, .timestamp = .none, .file_path = path });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("immediate", .{});

    // Visible on disk without any flush() call.
    const content = try readLogFileAlloc(io, cwd, path, gpa);
    defer gpa.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "immediate") != null);
}

test "flush policy: buffered holds file writes until flush()" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "flush_buffered.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
        .flush_policy = .buffered,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("one", .{});
    log.info("two", .{});

    // Still buffered: nothing on disk yet (lines are far below file_buf_bytes).
    try testing.expectEqual(@as(u64, 0), try fileSize(io, cwd, path));

    log.flush();

    const content = try readLogFileAlloc(io, cwd, path, gpa);
    defer gpa.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "one") != null);
    try testing.expect(std.mem.indexOf(u8, content, "two") != null);
}

test "flush policy: on_level buffers below threshold and drains at/above it" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "flush_on_level.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
        .flush_policy = .on_level, // flush_on_level defaults to .warn
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("buffered info", .{});
    try testing.expectEqual(@as(u64, 0), try fileSize(io, cwd, path)); // below threshold

    log.warn("flush now", .{}); // at threshold: drains the whole buffer

    const content = try readLogFileAlloc(io, cwd, path, gpa);
    defer gpa.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "buffered info") != null);
    try testing.expect(std.mem.indexOf(u8, content, "flush now") != null);
}

test "flush policy: close flushes buffered data" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "flush_close.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    {
        const Logger = make(.{
            .stderr = false,
            .timestamp = .none,
            .file_path = path,
            .flush_policy = .buffered,
        });
        var log = try Logger.open(gpa, io);
        defer log.close(io);
        log.info("at exit", .{}); // never explicitly flushed
    }

    const content = try readLogFileAlloc(io, cwd, path, gpa);
    defer gpa.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "at exit") != null);
}

test "flush policy: custom file_buf_bytes compiles and logs" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "flush_bufsize.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
        .flush_policy = .buffered,
        .file_buf_bytes = 64 * 1024,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("sized", .{});
    log.flush();

    const content = try readLogFileAlloc(io, cwd, path, gpa);
    defer gpa.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "sized") != null);
}

test "file rotation: size cap archives current file with timestamped suffix" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "rotate_size.log";

    deleteLogFamily(io, cwd, path);
    defer deleteLogFamily(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
        .file_rotation = .{ .size = .{ .max_bytes = 32 } },
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("first payload payload payload", .{});
    log.info("second", .{});
    log.flush();

    var archive_buf: [256]u8 = undefined;
    const archive = (try findSingleArchive(io, cwd, path, &archive_buf)) orelse return error.ExpectedArchive;

    const archived = try readLogFileAlloc(io, cwd, archive, gpa);
    defer gpa.free(archived);
    try testing.expectEqualStrings("[info] first payload payload payload\n", archived);

    const active = try readLogFileAlloc(io, cwd, path, gpa);
    defer gpa.free(active);
    try testing.expectEqualStrings("[info] second\n", active);
}

test "file rotation: buffered writes are flushed before archive rename" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "rotate_buffered.log";

    deleteLogFamily(io, cwd, path);
    defer deleteLogFamily(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
        .flush_policy = .buffered,
        .file_rotation = .{ .size = .{ .max_bytes = 32 } },
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    log.info("first payload payload payload", .{});

    var archive_buf: [256]u8 = undefined;
    const archive = (try findSingleArchive(io, cwd, path, &archive_buf)) orelse return error.ExpectedArchive;
    try testing.expect((try fileSize(io, cwd, archive)) > 0);
}

test "file rotation: same-second archives use collision suffixes" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "rotate_collision.log";
    const epoch_ms = 1622924906_000;

    deleteLogFamily(io, cwd, path);
    defer deleteLogFamily(io, cwd, path);

    try writeWholeFile(io, cwd, path, "first\n");
    var scratch1: [rotation_internal.timestampedScratchLen(path.len)]u8 = undefined;
    try rotation_internal.rotateTimestamped(io, cwd, path, epoch_ms, &scratch1);

    try writeWholeFile(io, cwd, path, "second\n");
    var scratch2: [rotation_internal.timestampedScratchLen(path.len)]u8 = undefined;
    try rotation_internal.rotateTimestamped(io, cwd, path, epoch_ms, &scratch2);

    const first_archive = "rotate_collision.log.2021-06-05T20-28-26Z";
    const second_archive = "rotate_collision.log.2021-06-05T20-28-26Z.001";

    const first = try readLogFileAlloc(io, cwd, first_archive, gpa);
    defer gpa.free(first);
    try testing.expectEqualStrings("first\n", first);

    const second = try readLogFileAlloc(io, cwd, second_archive, gpa);
    defer gpa.free(second);
    try testing.expectEqualStrings("second\n", second);
}

test "open cleanup: allocation failures do not leak without file sink" {
    try testing.checkAllAllocationFailures(testing.allocator, openCloseNoFile, .{});
}

test "open cleanup: allocation failures do not leak with file sink" {
    try testing.checkAllAllocationFailures(testing.allocator, openCloseWithFile, .{});
}

test "close cleanup: detached file writer buffer is released" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "detached_file_writer.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
    });
    var log = try Logger.open(gpa, io);
    if (log.file_sink.file) |f| {
        f.close(io);
        log.file_sink.file = null;
    }
    log.close(io);
}

test "file write failure increments stats counters" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "write_failure_bytes.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .file_path = path,
    });
    var log = try Logger.open(gpa, io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    if (log.file_sink.file) |f| f.close(io);
    log.info("this write cannot reach the closed file handle", .{});
    try testing.expectEqual(@as(usize, 1), mem.count());
    try testing.expect(std.mem.indexOf(u8, mem.entries()[0].line, "closed file handle") != null);

    const s = log.stats();
    try testing.expectEqual(@as(u64, 1), s.file_write_errors);
    try testing.expectEqual(@as(u64, 1), s.dropped_lines);

    log.file_sink.file = null;
    log.close(io);
}

test "stats: clean run reports zero counters" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("ok 1", .{});
    log.info("ok 2", .{});

    const s = log.stats();
    try testing.expectEqual(@as(u64, 0), s.dropped_lines);
    try testing.expectEqual(@as(u64, 0), s.file_write_errors);
}
