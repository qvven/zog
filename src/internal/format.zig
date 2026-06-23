const std = @import("std");
const Io = std.Io;
const time = @import("time.zig");

pub fn formatText(
    buf: []u8,
    comptime ts_kind: anytype,
    comptime source_kind: anytype,
    comptime scope_tag: anytype,
    comptime level: anytype,
    comptime src: anytype,
    comptime fmt: []const u8,
    args: anytype,
    prefix_fields: anytype,
    fields: anytype,
    io: Io,
) []const u8 {
    if (buf.len < 4) return buf[0..0];
    var pos: usize = time.writeTextTimestampPrefix(buf, ts_kind, io);

    const lvl_seg = std.fmt.bufPrint(buf[pos..], "[{s}] ", .{@tagName(level)}) catch return finishTruncatedText(buf, pos);
    pos += lvl_seg.len;

    if (comptime scope_tag != @TypeOf(scope_tag).default) {
        const sc_seg = std.fmt.bufPrint(buf[pos..], "[{s}] ", .{@tagName(scope_tag)}) catch return finishTruncatedText(buf, pos);
        pos += sc_seg.len;
    }

    if (comptime source_kind == .file_line) {
        if (comptime src) |loc| {
            const source_seg = std.fmt.bufPrint(buf[pos..], "{s}:{d} ", .{ loc.file, loc.line }) catch return finishTruncatedText(buf, pos);
            pos += source_seg.len;
        }
    }

    var body_writer: TextEscapeWriter = undefined;
    body_writer.init(buf, pos);
    var truncated = false;
    body_writer.writer.print(fmt, args) catch {
        truncated = true;
    };
    body_writer.writer.flush() catch {
        truncated = true;
    };
    if (body_writer.truncated) truncated = true;
    pos = body_writer.pos;
    if (truncated) return finishTruncatedText(buf, pos);

    if (writeTextFields(buf, &pos, prefix_fields)) |_| {} else |_| return finishTruncatedText(buf, pos);
    if (writeTextFields(buf, &pos, fields)) |_| {} else |_| return finishTruncatedText(buf, pos);

    return finishLine(buf, pos);
}

fn writeTextFields(buf: []u8, pos: *usize, fields: anytype) !void {
    const FieldsT = @TypeOf(fields);
    const fields_info = @typeInfo(FieldsT);
    if (fields_info != .@"struct") return;
    inline for (fields_info.@"struct".fields) |field| {
        const head = std.fmt.bufPrint(buf[pos.*..], " {s}=", .{field.name}) catch return error.NoSpaceLeft;
        pos.* += head.len;
        if (!writeTextValue(buf, pos, field.type, @field(fields, field.name))) return error.NoSpaceLeft;
    }
}

/// Append one value in text form. Recurses through optionals so a `?T` renders
/// as `null` or its unwrapped `T`. Returns false if the buffer ran out.
fn writeTextValue(buf: []u8, pos: *usize, comptime T: type, value: T) bool {
    if (comptime isStringLike(T)) {
        return writeTextEscapedBytes(buf, pos, asStringSlice(value));
    }
    switch (@typeInfo(T)) {
        .@"enum" => return writeTextEscapedBytes(buf, pos, @tagName(value)),
        .optional => {
            if (value) |inner| return writeTextValue(buf, pos, @TypeOf(inner), inner);
            return writeTextEscapedBytes(buf, pos, "null");
        },
        .bool, .int, .comptime_int, .float, .comptime_float => {
            // These render without any control characters, so write straight
            // into the line buffer and skip the escape pass.
            const seg = std.fmt.bufPrint(buf[pos.*..], "{any}", .{value}) catch return false;
            pos.* += seg.len;
            return true;
        },
        else => {
            // Exotic types: render to scratch, then escape so a control byte in
            // the output (e.g. an embedded newline) can't break the one-line
            // invariant. Mirrors the JSON formatter's fallback.
            var tmp: [128]u8 = undefined;
            const rendered = std.fmt.bufPrint(&tmp, "{any}", .{value}) catch tmp[0..0];
            return writeTextEscapedBytes(buf, pos, rendered);
        },
    }
}

/// Escape control bytes that would corrupt one-line text logs. Keeps newlines
/// out of the body so downstream line-oriented parsers stay sane.
fn writeTextEscapedBytes(buf: []u8, pos_in: *usize, s: []const u8) bool {
    var pos = pos_in.*;
    for (s) |c| {
        switch (c) {
            '\n' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                if (pos + 4 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                const hex = "0123456789abcdef";
                buf[pos] = '\\';
                buf[pos + 1] = 'x';
                buf[pos + 2] = hex[(c >> 4) & 0xF];
                buf[pos + 3] = hex[c & 0xF];
                pos += 4;
            },
            else => {
                if (pos + 1 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    pos_in.* = pos;
    return true;
}

const TextEscapeWriter = struct {
    out: []u8,
    pos: usize,
    truncated: bool,
    scratch: [64]u8,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn init(self: *TextEscapeWriter, out: []u8, pos: usize) void {
        self.* = .{
            .out = out,
            .pos = pos,
            .truncated = false,
            .scratch = undefined,
            .writer = undefined,
        };
        self.writer = .{
            .vtable = &vtable,
            .buffer = &self.scratch,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TextEscapeWriter = @fieldParentPtr("writer", w);

        const buffered = w.buffered();
        if (buffered.len != 0) {
            if (!writeTextEscapedBytes(self.out, &self.pos, buffered)) {
                self.truncated = true;
                w.end = 0;
                return error.WriteFailed;
            }
            w.end = 0;
        }

        for (data[0 .. data.len - 1]) |bytes| {
            if (!writeTextEscapedBytes(self.out, &self.pos, bytes)) {
                self.truncated = true;
                return error.WriteFailed;
            }
        }

        const repeated = data[data.len - 1];
        for (0..splat) |_| {
            if (!writeTextEscapedBytes(self.out, &self.pos, repeated)) {
                self.truncated = true;
                return error.WriteFailed;
            }
        }

        return std.Io.Writer.countSplat(data, splat);
    }
};

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |a| a.child == u8,
        else => false,
    };
}

fn asStringSlice(value: anytype) []const u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => value,
            .one => switch (@typeInfo(p.child)) {
                .array => value,
                else => @compileError("asStringSlice on non-string pointer"),
            },
            else => @compileError("asStringSlice on non-string pointer"),
        },
        .array => &value,
        else => @compileError("asStringSlice on non-string"),
    };
}

pub fn formatJson(
    buf: []u8,
    comptime ts_kind: anytype,
    comptime source_kind: anytype,
    comptime scope_tag: anytype,
    comptime level: anytype,
    comptime src: anytype,
    comptime fmt: []const u8,
    args: anytype,
    prefix_fields: anytype,
    fields: anytype,
    io: Io,
) []const u8 {
    if (buf.len < 8) return buf[0..0];
    // Reserve the final 3 bytes for `"}\n` so closing the object (and, when a
    // string value is cut off, its closing quote) never has to clamp back into
    // already-written content. Every field writer below sees only `work`;
    // whatever fits leaves room to close into a valid JSON object.
    const work = buf[0 .. buf.len - 3];
    var pos: usize = 0;
    var truncated = false;
    work[pos] = '{';
    pos += 1;
    // Last position at which the object can be validly closed (right after `{`
    // or after a complete `"key":value` member). Truncation rewinds here.
    var safe: usize = pos;

    switch (comptime ts_kind) {
        .none => {},
        .iso8601_utc => {
            if (work.len - pos < time.JSON_ISO8601_UTC_FIELD_LEN) return jsonCloseObject(buf, safe);
            const prefix = "\"ts\":\"";
            @memcpy(work[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            const ts = Io.Clock.now(.real, io).toMilliseconds();
            time.formatIso8601Utc(work[pos..][0..time.ISO8601_UTC_LEN], ts);
            pos += time.ISO8601_UTC_LEN;
            work[pos] = '"';
            pos += 1;
            work[pos] = ',';
            pos += 1;
        },
        .unix_ms => {
            const ts = Io.Clock.now(.real, io).toMilliseconds();
            const len = time.writeJsonUnixMsField(work[pos..], ts) orelse return jsonCloseObject(buf, safe);
            pos += len;
        },
    }

    {
        pos = writeJsonStaticStringField(work, pos, false, "level", @tagName(level), "\"".len) orelse return jsonCloseObject(buf, safe);
        safe = pos;
    }

    if (comptime scope_tag != @TypeOf(scope_tag).default) {
        pos = writeJsonStaticStringField(work, pos, true, "scope", @tagName(scope_tag), "\"".len) orelse return jsonCloseObject(buf, safe);
        safe = pos;
    }

    if (comptime source_kind == .file_line) {
        if (comptime src) |loc| {
            pos = writeJsonFieldName(work, pos, true, "file") orelse return jsonCloseObject(buf, safe);
            const file_result = writeJsonString(work, pos, loc.file);
            pos = file_result.pos;
            // A cut-off file value keeps what fit; close its quote and the
            // object (the `line` field is simply omitted).
            if (file_result.truncated) return jsonCloseString(buf, pos);
            pos = writeJsonFieldName(work, pos, true, "line") orelse return jsonCloseObject(buf, safe);
            const seg = std.fmt.bufPrint(work[pos..], "{d}", .{loc.line}) catch return jsonCloseObject(buf, safe);
            pos += seg.len;
            safe = pos;
        }
    }

    pos = writeJsonFieldName(work, pos, true, "msg") orelse return jsonCloseObject(buf, safe);
    if (pos >= work.len) return jsonCloseObject(buf, safe);
    work[pos] = '"';
    pos += 1;

    var msg_writer: JsonStringWriter = undefined;
    msg_writer.init(work, pos);
    msg_writer.writer.print(fmt, args) catch {
        truncated = true;
    };
    msg_writer.writer.flush() catch {
        truncated = true;
    };
    if (msg_writer.truncated) {
        truncated = true;
    }
    pos = msg_writer.pos;
    // A cut-off message keeps what fit; close its quote and the object.
    if (truncated or pos >= work.len) return jsonCloseString(buf, pos);
    work[pos] = '"';
    pos += 1;
    safe = pos;

    if (writeJsonFields(work, &pos, &safe, prefix_fields)) {} else {
        return jsonCloseObject(buf, safe);
    }
    if (writeJsonFields(work, &pos, &safe, fields)) {} else {
        return jsonCloseObject(buf, safe);
    }

    buf[pos] = '}';
    pos += 1;
    return finishLine(buf, pos);
}

/// Append `fields` as JSON object members. `safe` is advanced to the position
/// after each fully-written member so the caller can close the object at the
/// last valid boundary if a later member runs out of room. Returns false if the
/// buffer runs out partway.
fn writeJsonFields(buf: []u8, pos: *usize, safe: *usize, fields: anytype) bool {
    const FieldsT = @TypeOf(fields);
    const fields_info = @typeInfo(FieldsT);
    if (fields_info != .@"struct") return true;
    inline for (fields_info.@"struct".fields) |field| {
        const field_pos = writeJsonFieldName(buf, pos.*, true, field.name) orelse return false;
        pos.* = field_pos;
        if (!writeJsonValue(buf, pos, field.type, @field(fields, field.name))) return false;
        safe.* = pos.*;
    }
    return true;
}

/// Append one value as a JSON value. Recurses through optionals so a `?T`
/// renders as `null` or as its unwrapped `T`, never as a quoted `"null"`.
/// Returns false if the buffer ran out.
fn writeJsonValue(buf: []u8, pos: *usize, comptime T: type, value: T) bool {
    if (comptime isStringLike(T)) {
        const result = writeJsonString(buf, pos.*, asStringSlice(value));
        pos.* = result.pos;
        return !result.truncated;
    }
    switch (@typeInfo(T)) {
        .bool => {
            pos.* = writeJsonRawValue(buf, pos.*, if (value) "true" else "false") orelse return false;
        },
        .int, .comptime_int => {
            const seg = std.fmt.bufPrint(buf[pos.*..], "{d}", .{value}) catch return false;
            pos.* += seg.len;
        },
        .float, .comptime_float => {
            // JSON has no NaN/Infinity literals; emitting them bare would
            // produce output that strict parsers reject. Render non-finite
            // values as null, the conventional JSON stand-in.
            if (std.math.isFinite(value)) {
                const seg = std.fmt.bufPrint(buf[pos.*..], "{d}", .{value}) catch return false;
                pos.* += seg.len;
            } else {
                pos.* = writeJsonRawValue(buf, pos.*, "null") orelse return false;
            }
        },
        .@"enum" => {
            // Render enums as their tag name (a JSON string).
            const result = writeJsonString(buf, pos.*, @tagName(value));
            pos.* = result.pos;
            return !result.truncated;
        },
        .optional => {
            if (value) |inner| {
                return writeJsonValue(buf, pos, @TypeOf(inner), inner);
            }
            pos.* = writeJsonRawValue(buf, pos.*, "null") orelse return false;
        },
        else => {
            var tmp: [128]u8 = undefined;
            const rendered = std.fmt.bufPrint(&tmp, "{any}", .{value}) catch tmp[0..0];
            const result = writeJsonString(buf, pos.*, rendered);
            pos.* = result.pos;
            return !result.truncated;
        },
    }
    return true;
}

const WriteJsonStringResult = struct {
    pos: usize,
    truncated: bool,
};

fn copyBytes(buf: []u8, pos: usize, bytes: []const u8) ?usize {
    if (pos + bytes.len > buf.len) return null;
    @memcpy(buf[pos..][0..bytes.len], bytes);
    return pos + bytes.len;
}

fn writeJsonFieldName(buf: []u8, pos_in: usize, comma: bool, comptime name: []const u8) ?usize {
    var pos = pos_in;
    if (comma) {
        if (pos >= buf.len) return null;
        buf[pos] = ',';
        pos += 1;
    }
    if (pos >= buf.len) return null;
    buf[pos] = '"';
    pos += 1;
    pos = copyBytes(buf, pos, name) orelse return null;
    if (pos + 2 > buf.len) return null;
    buf[pos] = '"';
    buf[pos + 1] = ':';
    return pos + 2;
}

fn writeJsonRawValue(buf: []u8, pos: usize, bytes: []const u8) ?usize {
    return copyBytes(buf, pos, bytes);
}

fn writeJsonStaticStringField(
    buf: []u8,
    pos_in: usize,
    comma: bool,
    comptime name: []const u8,
    comptime value: []const u8,
    comptime tail_len: usize,
) ?usize {
    const field_len = @as(usize, if (comma) 1 else 0) + 2 + name.len + 1 + 2 + value.len + 1;
    if (buf.len - pos_in < field_len + tail_len) return null;

    var pos = writeJsonFieldName(buf, pos_in, comma, name) orelse unreachable;
    buf[pos] = '"';
    pos += 1;
    pos = copyBytes(buf, pos, value) orelse unreachable;
    buf[pos] = '"';
    return pos + 1;
}

const JsonStringWriter = struct {
    out: []u8,
    pos: usize,
    truncated: bool,
    scratch: [64]u8,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn init(self: *JsonStringWriter, out: []u8, pos: usize) void {
        self.* = .{
            .out = out,
            .pos = pos,
            .truncated = false,
            .scratch = undefined,
            .writer = undefined,
        };
        self.writer = .{
            .vtable = &vtable,
            .buffer = &self.scratch,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *JsonStringWriter = @fieldParentPtr("writer", w);

        const buffered = w.buffered();
        if (buffered.len != 0) {
            if (!writeJsonEscapedBytes(self.out, &self.pos, buffered)) {
                self.truncated = true;
                w.end = 0;
                return error.WriteFailed;
            }
            w.end = 0;
        }

        for (data[0 .. data.len - 1]) |bytes| {
            if (!writeJsonEscapedBytes(self.out, &self.pos, bytes)) {
                self.truncated = true;
                return error.WriteFailed;
            }
        }

        const repeated = data[data.len - 1];
        for (0..splat) |_| {
            if (!writeJsonEscapedBytes(self.out, &self.pos, repeated)) {
                self.truncated = true;
                return error.WriteFailed;
            }
        }

        return std.Io.Writer.countSplat(data, splat);
    }
};

fn writeJsonString(buf: []u8, pos_in: usize, s: []const u8) WriteJsonStringResult {
    var pos = pos_in;
    if (pos >= buf.len) return .{ .pos = pos, .truncated = true };
    buf[pos] = '"';
    pos += 1;
    const ok = writeJsonEscapedBytes(buf, &pos, s);
    if (!ok) return .{ .pos = pos, .truncated = true };
    if (pos >= buf.len) return .{ .pos = pos, .truncated = true };
    buf[pos] = '"';
    pos += 1;
    return .{ .pos = pos, .truncated = false };
}

fn writeJsonEscapedBytes(buf: []u8, pos_in: *usize, s: []const u8) bool {
    var pos = pos_in.*;
    for (s) |c| {
        switch (c) {
            '"' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                if (pos + 2 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                if (pos + 6 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                const hex = "0123456789abcdef";
                buf[pos] = '\\';
                buf[pos + 1] = 'u';
                buf[pos + 2] = '0';
                buf[pos + 3] = '0';
                buf[pos + 4] = hex[(c >> 4) & 0xF];
                buf[pos + 5] = hex[c & 0xF];
                pos += 6;
            },
            else => {
                if (pos + 1 > buf.len) {
                    pos_in.* = pos;
                    return false;
                }
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    pos_in.* = pos;
    return true;
}

/// Close an object whose last value is an unterminated string: write the
/// closing quote, then close the object. `pos` is the position just past the
/// string content; `formatJson`'s 3-byte tail reserve guarantees room for `"`,
/// `}`, and `\n`. The `,"truncated":true` marker is only appended if it still
/// fits after the quote. It is a hint, not a guarantee, and is never inserted
/// by rewinding into the (possibly multi-byte-escaped) string content, which
/// could split an escape sequence and produce invalid JSON.
fn jsonCloseString(buf: []u8, pos: usize) []const u8 {
    buf[pos] = '"';
    return jsonCloseObject(buf, pos + 1);
}

/// Close a JSON object at `pos`, a valid member boundary (right after `{`,
/// after a complete `"key":value`, or after a `jsonCloseString` quote).
/// Appends a `,"truncated":true` marker when it fits and the object is
/// non-empty, then `}` and a newline. Callers pass a `pos` that already
/// reserves room for `}\n`, so this never clamps back into written content and
/// the result always parses as JSON.
fn jsonCloseObject(buf: []u8, pos: usize) []const u8 {
    var end = pos;
    const marker = ",\"truncated\":true";
    // `end > 1` skips the marker for an empty object (`{}`), where a leading
    // comma would be invalid.
    if (end > 1 and end + marker.len + 2 <= buf.len) {
        @memcpy(buf[end..][0..marker.len], marker);
        end += marker.len;
    }
    buf[end] = '}';
    buf[end + 1] = '\n';
    return buf[0 .. end + 2];
}

fn finishTruncatedText(buf: []u8, pos: usize) []const u8 {
    const marker = " [truncated]\n";
    if (buf.len < marker.len) return finishLine(buf, pos);
    // Place the marker right after the content that fit. If there is no room,
    // back up into the content so the marker still lands inside the buffer.
    // Returning a slice that ends at the marker (rather than the full buffer)
    // keeps stale bytes from the previous line (`line_buf` is reused) out of
    // the emitted line.
    const start = @min(pos, buf.len - marker.len);
    @memcpy(buf[start..][0..marker.len], marker);
    return buf[0 .. start + marker.len];
}

fn finishLine(buf: []u8, pos: usize) []const u8 {
    const end = @min(pos, buf.len - 1);
    buf[end] = '\n';
    return buf[0 .. end + 1];
}
