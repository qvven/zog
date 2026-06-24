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

test "public api contract: root exports stable v0.1 surface" {
    try testing.expect(@hasDecl(zog, "Level"));
    try testing.expect(@hasDecl(zog, "NoScope"));
    try testing.expect(@hasDecl(zog, "TimestampFormat"));
    try testing.expect(@hasDecl(zog, "LineFormat"));
    try testing.expect(@hasDecl(zog, "SourceMode"));
    try testing.expect(!@hasDecl(zog, "ColorMode"));
    try testing.expect(@hasDecl(zog, "Sink"));
    try testing.expect(@hasDecl(zog, "MemorySink"));
    try testing.expect(@hasDecl(zog, "Stats"));
    try testing.expect(@hasDecl(zog, "Config"));
    try testing.expect(@hasDecl(zog, "make"));
    try testing.expect(@hasDecl(zog, "FileRotation"));
    try testing.expect(@hasDecl(zog, "SizeRotation"));
    try testing.expect(@hasDecl(zog, "FlushPolicy"));
    try testing.expect(@hasField(zog.Stats, "dropped_lines"));
    try testing.expect(@hasField(zog.Stats, "file_write_errors"));
    try testing.expect(!@hasField(zog.Stats, "extra_sink_errors"));

    const cfg: zog.Config = .{};
    try testing.expectEqual(Level.info, cfg.min_level);
    try testing.expectEqual(zog.TimestampFormat.iso8601_utc, cfg.timestamp);
    try testing.expectEqual(zog.LineFormat.text, cfg.format);
    try testing.expectEqual(zog.SourceMode.none, cfg.source);
    try testing.expectEqual(true, cfg.stderr);
    try testing.expectEqual(@as(?[]const u8, null), cfg.file_path);
    try testing.expectEqual(zog.FileRotation.none, cfg.file_rotation);
    try testing.expectEqual(zog.FlushPolicy.every_line, cfg.flush_policy);
    try testing.expectEqual(Level.warn, cfg.flush_on_level);
    try testing.expectEqual(@as(usize, 4096), cfg.file_buf_bytes);
    try testing.expectEqual(@as(usize, 1024), cfg.max_line_bytes);
    try testing.expectEqual(true, cfg.thread_safe);
}

test "public api contract: common v0.1 workflow compiles and emits expected line" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Scope = enum {
        default,
        api,
        pub fn minLevel(comptime s: @This()) Level {
            return switch (s) {
                .api => .debug,
                else => .info,
            };
        }
    };

    const Logger = zog.make(.{
        .Scope = Scope,
        .stderr = false,
        .timestamp = .none,
        .source = .file_line,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const loc = @src();
    log.scope(.api).with(.{ .request_id = "rid" }).at(loc).debug("handled", .{
        .status = @as(u16, 200),
    });

    try testing.expectEqual(@as(usize, 1), mem.count());
    const entry = mem.entries()[0];
    try testing.expectEqual(Level.debug, entry.level);
    try testing.expectEqualStrings("api", entry.scope_name);
    try testing.expect(std.mem.indexOf(u8, entry.line, "[debug] [api]") != null);
    try testing.expect(std.mem.indexOf(u8, entry.line, "handled request_id=rid status=200") != null);

    var expected_line: [32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&expected_line, ":{d} ", .{loc.line});
    try testing.expect(std.mem.indexOf(u8, entry.line, marker) != null);
}

test "level filter: debug below min_level=.info skips sinks" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .min_level = .info });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.debug("should be filtered", .{});
    log.info("should pass", .{});

    const entries = mem.entries();
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(Level.info, entries[0].level);
    try testing.expect(std.mem.indexOf(u8, entries[0].line, "should pass") != null);
    try testing.expect(std.mem.indexOf(u8, mem.bytes(), "should be filtered") == null);
}

test "scope filter: per-scope minLevel lets .db emit only err" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Scope = enum {
        default,
        auth,
        db,
        pub fn minLevel(comptime s: @This()) Level {
            return switch (s) {
                .db => .err,
                else => .info,
            };
        }
    };

    const Logger = make(.{ .stderr = false, .Scope = Scope, .min_level = .info });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const auth = log.scope(.auth);
    const db = log.scope(.db);

    auth.info("auth ok", .{});
    db.info("db chatter", .{});
    db.err("db down", .{});
    log.info("default channel", .{});

    const entries = mem.entries();
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("auth", entries[0].scope_name);
    try testing.expectEqualStrings("db", entries[1].scope_name);
    try testing.expectEqual(Level.err, entries[1].level);
    try testing.expectEqualStrings("default", entries[2].scope_name);

    try testing.expect(std.mem.indexOf(u8, mem.bytes(), "db chatter") == null);
}

test "line format: default scope omits the scope segment" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Scope = enum { default, auth };
    const Logger = make(.{ .stderr = false, .Scope = Scope, .timestamp = .unix_ms });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("plain", .{});
    const auth = log.scope(.auth);
    auth.warn("scoped", .{});

    const entries = mem.entries();
    try testing.expectEqual(@as(usize, 2), entries.len);

    const default_line = entries[0].line;
    try testing.expect(std.mem.endsWith(u8, default_line, "] [info] plain\n"));
    try testing.expect(std.mem.indexOf(u8, default_line, "[default]") == null);

    const scoped_line = entries[1].line;
    try testing.expect(std.mem.indexOf(u8, scoped_line, "[warn] [auth] scoped\n") != null);
}

test "iso8601 timestamp: formatIso8601Utc renders expected components" {
    var buf: [24]u8 = undefined;

    time_internal.formatIso8601Utc(&buf, 0);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &buf);

    time_internal.formatIso8601Utc(&buf, 1622924906_000);
    try testing.expectEqualStrings("2021-06-05T20:28:26.000Z", &buf);

    time_internal.formatIso8601Utc(&buf, 1622924906_123);
    try testing.expectEqualStrings("2021-06-05T20:28:26.123Z", &buf);

    time_internal.formatIso8601Utc(&buf, -42);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &buf);
}

test "timestamp constants describe fixed ISO field widths" {
    try testing.expectEqual(@as(usize, 24), time_internal.ISO8601_UTC_LEN);
    try testing.expectEqual(@as(usize, 27), time_internal.TEXT_ISO8601_UTC_PREFIX_LEN);
    try testing.expectEqual(@as(usize, 32), time_internal.JSON_ISO8601_UTC_FIELD_LEN);
    try testing.expectEqual(@as(usize, 20), time_internal.ARCHIVE_TIMESTAMP_LEN);
}

test "archive timestamp uses filesystem-friendly UTC separators" {
    var buf: [time_internal.ARCHIVE_TIMESTAMP_LEN]u8 = undefined;
    time_internal.formatArchiveTimestamp(&buf, 1622924906_123);
    try testing.expectEqualStrings("2021-06-05T20-28-26Z", &buf);
}

test "unix_ms timestamp writers render expected text and json fields" {
    var text_buf: [32]u8 = undefined;
    const text_len = time_internal.writeTextUnixMsPrefix(&text_buf, 1234567890);
    try testing.expectEqualStrings("[1234567890] ", text_buf[0..text_len]);

    var json_buf: [32]u8 = undefined;
    const json_len = time_internal.writeJsonUnixMsField(&json_buf, 1234567890) orelse unreachable;
    try testing.expectEqualStrings("\"ts\":1234567890,", json_buf[0..json_len]);

    var tiny: [8]u8 = undefined;
    try testing.expectEqual(null, time_internal.writeJsonUnixMsField(&tiny, 1234567890));
}

test "timestamp = .none omits the entire ts segment" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hello", .{});
    try testing.expectEqualStrings("[info] hello\n", mem.entries()[0].line);
}

test "source file_line: text info via at(@src()) includes caller file and line" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none, .source = .file_line });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const loc = @src();
    log.at(loc).info("located", .{});

    const line = mem.entries()[0].line;
    var expected_prefix: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&expected_prefix, "[info] {s}:", .{loc.file});
    try testing.expect(std.mem.startsWith(u8, line, prefix));
    try testing.expect(std.mem.indexOf(u8, line, " located\n") != null);

    var expected: [32]u8 = undefined;
    const rendered_line = try std.fmt.bufPrint(&expected, ":{d} ", .{loc.line});
    try testing.expect(std.mem.indexOf(u8, line, rendered_line) != null);
}

test "timestamp = .iso8601_utc emits a 24-byte ISO string prefix" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hi", .{});
    const line = mem.entries()[0].line;
    try testing.expectEqual(@as(u8, '['), line[0]);
    try testing.expectEqual(@as(u8, '-'), line[5]);
    try testing.expectEqual(@as(u8, '-'), line[8]);
    try testing.expectEqual(@as(u8, 'T'), line[11]);
    try testing.expectEqual(@as(u8, ':'), line[14]);
    try testing.expectEqual(@as(u8, ':'), line[17]);
    try testing.expectEqual(@as(u8, '.'), line[20]);
    try testing.expectEqual(@as(u8, 'Z'), line[24]);
    try testing.expectEqualStrings("] [info] hi\n", line[25..]);
}

test "thread safety: concurrent writes keep count and avoid interleaving" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const Worker = struct {
        fn run(l: *Logger, id: u32) void {
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                l.info("t{d}-msg{d}", .{ id, i });
            }
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &log, @as(u32, @intCast(i)) });
    }
    for (&threads) |t| t.join();

    const entries = mem.entries();
    try testing.expectEqual(@as(usize, 8 * 1000), entries.len);

    for (entries) |e| {
        try testing.expect(e.line.len > 0);
        try testing.expectEqual(@as(u8, '\n'), e.line[e.line.len - 1]);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, e.line, "\n"));
    }
}
