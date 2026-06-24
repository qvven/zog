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
