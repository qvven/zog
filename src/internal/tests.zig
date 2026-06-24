const std = @import("std");
const testing = std.testing;
const zog = @import("../zog.zig");

const Level = zog.Level;
const MemorySink = zog.MemorySink;
const make = zog.make;
const time_internal = @import("time.zig");
const rotation_internal = @import("rotation.zig");

fn parseJsonLine(gpa: std.mem.Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, std.mem.trimEnd(u8, line, "\n"), .{});
}

fn expectJsonString(obj: anytype, key: []const u8, expected: []const u8) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    switch (value) {
        .string => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

fn expectJsonInteger(obj: anytype, key: []const u8, expected: i64) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    switch (value) {
        .integer => |actual| try testing.expectEqual(expected, actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

fn expectJsonBool(obj: anytype, key: []const u8, expected: bool) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    switch (value) {
        .bool => |actual| try testing.expectEqual(expected, actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

fn expectJsonNull(obj: anytype, key: []const u8) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    try testing.expect(value == .null);
}

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

test "json format: default scope outputs ts/level/msg and no scope field" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .unix_ms,
        .format = .json,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hello {s}", .{"world"});

    const line = mem.entries()[0].line;
    var parsed = try parseJsonLine(gpa, line);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.contains("ts"));
    try expectJsonString(obj, "level", "info");
    try expectJsonString(obj, "msg", "hello world");
    try testing.expect(!obj.contains("scope"));
}

test "json format: custom scope field appears and msg escapes characters" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Scope = enum { default, auth };
    const Logger = make(.{
        .stderr = false,
        .Scope = Scope,
        .timestamp = .none,
        .format = .json,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const auth = log.scope(.auth);
    auth.warn("user said: \"hi\\there\"\n", .{});

    const line = mem.entries()[0].line;
    const expected = "{\"level\":\"warn\",\"scope\":\"auth\",\"msg\":\"user said: \\\"hi\\\\there\\\"\\n\"}\n";
    try testing.expectEqualStrings(expected, line);
}

test "json format: ts = .iso8601_utc emits a string timestamp" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .format = .json });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hi", .{});
    const line = mem.entries()[0].line;
    var parsed = try parseJsonLine(gpa, line);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const ts = obj.get("ts") orelse return error.MissingJsonField;
    try testing.expect(ts == .string);
    try testing.expectEqual(@as(usize, time_internal.ISO8601_UTC_LEN), ts.string.len);
    try testing.expectEqual(@as(u8, 'Z'), ts.string[time_internal.ISO8601_UTC_LEN - 1]);
    try expectJsonString(obj, "level", "info");
}

test "json format: timestamp = .none omits ts field" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hi", .{});
    try testing.expectEqualStrings("{\"level\":\"info\",\"msg\":\"hi\"}\n", mem.entries()[0].line);
}

test "json output parses as valid JSON across mixed field types" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Color = enum { red, green, blue };

    const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
    var log = try Logger.open(gpa, io);
    defer log.close(io);
    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("event", .{
        .s = "a\"b\nc", // needs escaping
        .i = @as(i64, -5),
        .f = @as(f64, 1.5),
        .nan = std.math.nan(f64),
        .b = true,
        .e = Color.red,
        .opt_some = @as(?u8, 3),
        .opt_none = @as(?u8, null),
    });

    // Parsing the emitted line is the strongest guard that escaping,
    // null handling, enums, and optionals all produce well-formed output.
    var parsed = try parseJsonLine(gpa, mem.entries()[0].line);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try expectJsonString(obj, "s", "a\"b\nc");
    try expectJsonInteger(obj, "i", -5);
    try expectJsonNull(obj, "nan");
    try expectJsonBool(obj, "b", true);
    try expectJsonString(obj, "e", "red");
    try expectJsonInteger(obj, "opt_some", 3);
    try expectJsonNull(obj, "opt_none");
}

test "kv optional fields unwrap: null renders as null, present unwraps to inner" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        const Logger = make(.{ .stderr = false, .timestamp = .none });
        var log = try Logger.open(gpa, io);
        defer log.close(io);
        var mem = MemorySink.init(gpa);
        defer mem.deinit();
        try log.addSink(mem.sink());

        const some: ?u32 = 7;
        const none: ?u32 = null;
        log.info("opt", .{ .a = some, .b = none });
        try testing.expectEqualStrings("[info] opt a=7 b=null\n", mem.entries()[0].line);
    }

    {
        const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
        var log = try Logger.open(gpa, io);
        defer log.close(io);
        var mem = MemorySink.init(gpa);
        defer mem.deinit();
        try log.addSink(mem.sink());

        const some: ?u32 = 7;
        const none: ?u32 = null;
        log.info("opt", .{ .a = some, .b = none });
        // Present optional unwraps to a bare number; null is a real JSON null,
        // not a quoted "null".
        try testing.expectEqualStrings(
            "{\"level\":\"info\",\"msg\":\"opt\",\"a\":7,\"b\":null}\n",
            mem.entries()[0].line,
        );
    }
}

test "kv enum fields render by tag name in text and json" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Color = enum { red, green, blue };

    {
        const Logger = make(.{ .stderr = false, .timestamp = .none });
        var log = try Logger.open(gpa, io);
        defer log.close(io);
        var mem = MemorySink.init(gpa);
        defer mem.deinit();
        try log.addSink(mem.sink());

        log.info("paint", .{ .color = Color.green });
        try testing.expectEqualStrings("[info] paint color=green\n", mem.entries()[0].line);
    }

    {
        const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
        var log = try Logger.open(gpa, io);
        defer log.close(io);
        var mem = MemorySink.init(gpa);
        defer mem.deinit();
        try log.addSink(mem.sink());

        log.info("paint", .{ .color = Color.blue });
        try testing.expectEqualStrings(
            "{\"level\":\"info\",\"msg\":\"paint\",\"color\":\"blue\"}\n",
            mem.entries()[0].line,
        );
    }
}

test "json kv: non-finite floats render as null, finite ones normally" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("metrics", .{
        .nan = std.math.nan(f64),
        .inf = std.math.inf(f64),
        .ok = @as(f64, 1.5),
    });

    var parsed = try parseJsonLine(gpa, mem.entries()[0].line);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try expectJsonNull(obj, "nan");
    try expectJsonNull(obj, "inf");
    const ok = obj.get("ok") orelse return error.MissingJsonField;
    switch (ok) {
        .float => |actual| try testing.expectEqual(@as(f64, 1.5), actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

test "json format: truncated escaped msg stays valid and closed" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .max_line_bytes = 38,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("payload \"\\\\\"\n \"\\\\\"\n \"\\\\\"\n \"\\\\\"\n", .{});

    const line = mem.entries()[0].line;
    try testing.expect(std.mem.startsWith(u8, line, "{"));
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    // The real guarantee: a truncated line is still parseable JSON.
    var parsed = try parseJsonLine(gpa, line);
    parsed.deinit();
}

test "json format: truncated msg stays valid and closed" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .max_line_bytes = 80,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("payload payload payload payload payload payload payload payload payload", .{});

    const line = mem.entries()[0].line;
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    var parsed = try parseJsonLine(gpa, line);
    parsed.deinit();
}

test "json format: message uses full line capacity before truncating" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .max_line_bytes = 96,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", .{});

    try testing.expectEqualStrings(
        "{\"level\":\"info\",\"msg\":\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\"}\n",
        mem.entries()[0].line,
    );
}

test "json format: tiny buffer falls back to empty object" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .max_line_bytes = 16,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hello", .{});

    try testing.expectEqualStrings("{}\n", mem.entries()[0].line);
}

test "json format: truncated kv string field stays valid" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .max_line_bytes = 96,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("event", .{
        .payload = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    });

    const line = mem.entries()[0].line;
    try testing.expect(std.mem.startsWith(u8, line, "{"));
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    var parsed = try parseJsonLine(gpa, line);
    parsed.deinit();
}

test "json format: truncated source file field stays valid JSON" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // When the `file` source field is cut off mid-string by the line cap, the
    // line must still be parseable JSON (the open quote has to be closed before
    // the `,"truncated":true}` tail). Sweep a range of caps so that whatever the
    // compiled-in source path length is, some cap lands inside the `"file":"..."`
    // value and exercises the truncation path. For every cap that produced a
    // line carrying a `"file"` key, std.json must accept the whole line.
    inline for (.{ 40, 44, 48, 52, 56, 60, 64, 68, 72, 76, 80 }) |cap| {
        const Logger = make(.{
            .stderr = false,
            .timestamp = .none,
            .format = .json,
            .source = .file_line,
            .max_line_bytes = cap,
        });
        var log = try Logger.open(gpa, io);
        defer log.close(io);

        var mem = MemorySink.init(gpa);
        defer mem.deinit();
        try log.addSink(mem.sink());

        log.at(@src()).info("connected", .{});

        const line = mem.entries()[0].line;
        if (std.mem.indexOf(u8, line, "\"file\"") != null) {
            var parsed = parseJsonLine(gpa, line) catch |e| {
                std.debug.print("cap={d} produced invalid JSON: {s}\n", .{ cap, line });
                return e;
            };
            parsed.deinit();
        }
    }
}

test "json format: truncated numeric and bool kv fields stay valid" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .max_line_bytes = 72,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.warn("metrics", .{
        .attempts = @as(u64, 18446744073709551615),
        .blocked = true,
        .ratio = @as(f64, 12345.6789),
    });

    const line = mem.entries()[0].line;
    try testing.expect(std.mem.startsWith(u8, line, "{"));
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    var parsed = try parseJsonLine(gpa, line);
    parsed.deinit();
}

test "text format: truncated msg is marked" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .max_line_bytes = 48,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("payload payload payload payload payload payload", .{});

    const line = mem.entries()[0].line;
    try testing.expect(std.mem.endsWith(u8, line, " [truncated]\n"));
}

test "text format: truncated line carries no stale bytes after marker" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .max_line_bytes = 32,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    // First, fill the reused line_buf with a distinctive byte pattern via a
    // line that fits; then emit a truncating line. The truncated slice must end
    // at the marker and never expose leftover 'Z's from the previous line.
    log.info("ZZZZZZZZZZZZZZZZZZZZZZZZZ", .{});
    log.info("payload payload payload payload payload", .{});

    const line = mem.entries()[1].line;
    try testing.expect(std.mem.endsWith(u8, line, " [truncated]\n"));
    // The slice ends exactly at the marker; nothing trails it.
    const marker = " [truncated]\n";
    try testing.expectEqual(line.len, std.mem.indexOf(u8, line, marker).? + marker.len);
    try testing.expect(std.mem.indexOf(u8, line, "Z") == null);
}

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

test "kv text: fields append after body with integer/string/bool values" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("user login", .{ .user = "ada", .uid = @as(u32, 42), .ok = true });

    try testing.expectEqualStrings(
        "[info] user login user=ada uid=42 ok=true\n",
        mem.entries()[0].line,
    );
}

test "payload dispatch: same method handles format args and kv fields" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    // Positional tuple -> format args.
    log.info("hello {s} #{d}", .{ "world", @as(u32, 7) });
    // Named struct -> kv fields, msg printed verbatim.
    log.info("user login", .{ .user = "ada", .ok = true });
    // Empty payload -> neither; bare message.
    log.info("ready", .{});

    try testing.expectEqualStrings("[info] hello world #7\n", mem.entries()[0].line);
    try testing.expectEqualStrings("[info] user login user=ada ok=true\n", mem.entries()[1].line);
    try testing.expectEqualStrings("[info] ready\n", mem.entries()[2].line);
}

test "payload dispatch: braces in a kv-field message are printed literally" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    // No `{}` placeholders here, so the named-struct branch prints the
    // message as-is and appends the field.
    log.warn("done", .{ .count = @as(u32, 3) });

    try testing.expectEqualStrings("[warn] done count=3\n", mem.entries()[0].line);
}

test "kv json: fields become JSON properties and strings are escaped" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none, .format = .json });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.warn("auth fail", .{
        .user = "with \"quotes\"",
        .attempts = @as(u8, 3),
        .blocked = false,
    });

    const expected =
        "{\"level\":\"warn\",\"msg\":\"auth fail\"" ++
        ",\"user\":\"with \\\"quotes\\\"\"" ++
        ",\"attempts\":3" ++
        ",\"blocked\":false}\n";
    try testing.expectEqualStrings(expected, mem.entries()[0].line);
}

test "source file_line: json kv via at(@src()) includes file and line fields" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .format = .json,
        .source = .file_line,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    const loc = @src();
    log.at(loc).warn("auth fail", .{ .user = "ada" });

    const line = mem.entries()[0].line;
    var parsed = try parseJsonLine(gpa, line);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try expectJsonString(obj, "level", "warn");
    try expectJsonString(obj, "file", loc.file);
    try expectJsonInteger(obj, "line", @intCast(loc.line));
    try expectJsonString(obj, "msg", "auth fail");
    try expectJsonString(obj, "user", "ada");
}

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

test "text format: truncated kv fields are marked" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = false,
        .timestamp = .none,
        .max_line_bytes = 56,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("event", .{
        .payload = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    });

    const line = mem.entries()[0].line;
    try testing.expect(std.mem.startsWith(u8, line, "[info] event payload="));
    try testing.expect(std.mem.endsWith(u8, line, " [truncated]\n"));
}

test "text format: exotic {any} field value renders and stays one line" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    // A struct field has no native renderer and falls back to `{any}`. The
    // fallback routes through the text escaper, so even if a rendering ever
    // contained a control byte the line stays single; here we assert the
    // value renders and exactly one trailing newline is present.
    const Point = struct { x: u8, y: bool };
    log.info("event", .{ .p = Point{ .x = 7, .y = true } });

    try testing.expectEqual(@as(usize, 1), mem.count());
    const line = mem.entries()[0].line;
    try testing.expect(std.mem.indexOf(u8, line, "p=.{ .x = 7, .y = true }") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
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

test "text format: newlines and control chars in body are escaped" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("user said: {s}", .{"line1\nline2\twith\rtab"});

    try testing.expectEqualStrings(
        "[info] user said: line1\\nline2\\twith\\rtab\n",
        mem.entries()[0].line,
    );
    // Exactly one terminating LF; body LF was escaped.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, mem.entries()[0].line, "\n"));
}

test "text format: bell and DEL escape as \\xNN" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("ctrl: {s}", .{"\x07\x7f\x1b"});

    try testing.expectEqualStrings(
        "[info] ctrl: \\x07\\x7f\\x1b\n",
        mem.entries()[0].line,
    );
}

test "text format: kv string fields escape control chars too" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("got input", .{ .body = "a\nb\tc", .ok = true });

    try testing.expectEqualStrings(
        "[info] got input body=a\\nb\\tc ok=true\n",
        mem.entries()[0].line,
    );
}

test "text format: utf-8 multibyte bytes pass through unchanged" {
    const gpa = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{ .stderr = false, .timestamp = .none });
    var log = try Logger.open(gpa, io);
    defer log.close(io);

    var mem = MemorySink.init(gpa);
    defer mem.deinit();
    try log.addSink(mem.sink());

    log.info("hello {s}", .{"世界 🌍"});

    try testing.expectEqualStrings(
        "[info] hello 世界 🌍\n",
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

fn openCloseNoFile(gpa: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = true,
        .timestamp = .none,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);
}

const DropSink = struct {
    count: usize = 0,

    fn sink(self: *DropSink) zog.Sink {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: zog.Sink.VTable = .{ .write = write };

    fn write(ptr: *anyopaque, _: Level, _: []const u8, _: []const u8) void {
        const self: *DropSink = @ptrCast(@alignCast(ptr));
        self.count += 1;
    }
};

fn deleteLogFiles(io: std.Io, cwd: std.Io.Dir, path: []const u8) void {
    cwd.deleteFile(io, path) catch {};
}

fn deleteLogFamily(io: std.Io, cwd: std.Io.Dir, path: []const u8) void {
    cwd.deleteFile(io, path) catch {};
    var dir = cwd.openDir(io, ".", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}.", .{path}) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            dir.deleteFile(io, entry.name) catch {};
        }
    }
}

fn writeWholeFile(io: std.Io, cwd: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [64]u8 = undefined;
    var writer = f.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn findSingleArchive(io: std.Io, cwd: std.Io.Dir, path: []const u8, out: []u8) !?[]const u8 {
    var dir = try cwd.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}.", .{path});
    var found: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (found != null) return error.UnexpectedExtraArchive;
        if (entry.name.len > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..entry.name.len], entry.name);
        found = out[0..entry.name.len];
    }
    return found;
}

/// Read the full current contents of `path` into an allocated buffer (caller
/// frees). Used by flush-policy tests to observe the file while the logger is
/// still open.
fn readLogFileAlloc(io: std.Io, cwd: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const len: usize = @intCast(try f.length(io));
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    if (len > 0) {
        var rbuf: [512]u8 = undefined;
        var reader = f.reader(io, &rbuf);
        const n = try reader.interface.readSliceShort(out);
        if (n != len) return error.ShortRead;
    }
    return out;
}

fn fileSize(io: std.Io, cwd: std.Io.Dir, path: []const u8) !u64 {
    const f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    return f.length(io);
}

fn openCloseWithFile(gpa: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const path = "resource_open_failure.log";

    deleteLogFiles(io, cwd, path);
    defer deleteLogFiles(io, cwd, path);

    const Logger = make(.{
        .stderr = true,
        .timestamp = .none,
        .file_path = path,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);
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
