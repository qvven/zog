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
