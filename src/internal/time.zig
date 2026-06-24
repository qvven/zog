const std = @import("std");
const Io = std.Io;

pub const ISO8601_UTC_LEN: usize = 24;
pub const TEXT_ISO8601_UTC_PREFIX_LEN: usize = 27;
pub const JSON_ISO8601_UTC_FIELD_LEN: usize = "\"ts\":\"".len + ISO8601_UTC_LEN + "\",".len;
pub const ARCHIVE_TIMESTAMP_LEN: usize = 20;

/// Write a unix epoch millisecond value as fixed-width ISO 8601 UTC.
/// Output is exactly 24 bytes: `2026-06-16T15:30:42.123Z`.
pub fn formatIso8601Utc(out: []u8, epoch_ms: i64) void {
    std.debug.assert(out.len >= ISO8601_UTC_LEN);
    const ms_clamped: u64 = if (epoch_ms < 0) 0 else @intCast(epoch_ms);
    const secs = ms_clamped / 1000;
    const ms_part: u16 = @intCast(ms_clamped % 1000);

    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_seconds.getEpochDay();
    const day_secs = epoch_seconds.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();

    printDigits(out[0..4], yd.year, 4);
    out[4] = '-';
    printDigits(out[5..7], @intFromEnum(md.month), 2);
    out[7] = '-';
    printDigits(out[8..10], @as(u16, md.day_index) + 1, 2);
    out[10] = 'T';
    printDigits(out[11..13], day_secs.getHoursIntoDay(), 2);
    out[13] = ':';
    printDigits(out[14..16], day_secs.getMinutesIntoHour(), 2);
    out[16] = ':';
    printDigits(out[17..19], day_secs.getSecondsIntoMinute(), 2);
    out[19] = '.';
    printDigits(out[20..23], ms_part, 3);
    out[23] = 'Z';
}

/// Write a filesystem-friendly UTC timestamp for rotated log archives.
/// Output is exactly 20 bytes: `2026-06-16T15-30-42Z`.
pub fn formatArchiveTimestamp(out: []u8, epoch_ms: i64) void {
    std.debug.assert(out.len >= ARCHIVE_TIMESTAMP_LEN);
    var iso: [ISO8601_UTC_LEN]u8 = undefined;
    formatIso8601Utc(&iso, epoch_ms);
    @memcpy(out[0..13], iso[0..13]);
    out[13] = '-';
    @memcpy(out[14..16], iso[14..16]);
    out[16] = '-';
    @memcpy(out[17..19], iso[17..19]);
    out[19] = 'Z';
}

fn printDigits(out: []u8, value: anytype, comptime width: usize) void {
    std.debug.assert(out.len == width);
    var v: u64 = @intCast(value);
    var i: usize = width;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

pub fn writeTextUnixMsPrefix(buf: []u8, epoch_ms: i64) usize {
    if (buf.len < 4) return 0;
    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    pos = writeSignedDecimal(buf, pos, epoch_ms) orelse return 0;
    if (pos + 2 > buf.len) return 0;
    buf[pos] = ']';
    buf[pos + 1] = ' ';
    return pos + 2;
}

pub fn writeJsonUnixMsField(buf: []u8, epoch_ms: i64) ?usize {
    const prefix = "\"ts\":";
    if (buf.len < prefix.len + 2) return null;
    @memcpy(buf[0..prefix.len], prefix);
    var pos = writeSignedDecimal(buf, prefix.len, epoch_ms) orelse return null;
    if (pos >= buf.len) return null;
    buf[pos] = ',';
    pos += 1;
    return pos;
}

fn writeSignedDecimal(buf: []u8, pos_in: usize, value: i64) ?usize {
    var pos = pos_in;
    var abs_value: u64 = undefined;
    if (value < 0) {
        if (pos >= buf.len) return null;
        buf[pos] = '-';
        pos += 1;
        abs_value = @abs(value);
    } else {
        abs_value = @intCast(value);
    }

    var digits: [20]u8 = undefined;
    var i: usize = digits.len;
    var n = abs_value;
    while (true) {
        i -= 1;
        digits[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }

    const rendered = digits[i..];
    if (pos + rendered.len > buf.len) return null;
    @memcpy(buf[pos..][0..rendered.len], rendered);
    return pos + rendered.len;
}

/// Write the text-format timestamp prefix into `buf`.
pub fn writeTextTimestampPrefix(buf: []u8, comptime kind: anytype, io: Io) usize {
    return switch (kind) {
        .none => 0,
        .unix_ms => blk: {
            const ts = Io.Clock.now(.real, io).toMilliseconds();
            break :blk writeTextUnixMsPrefix(buf, ts);
        },
        .iso8601_utc => blk: {
            if (buf.len < TEXT_ISO8601_UTC_PREFIX_LEN) break :blk 0;
            const ts = Io.Clock.now(.real, io).toMilliseconds();
            buf[0] = '[';
            formatIso8601Utc(buf[1..][0..ISO8601_UTC_LEN], ts);
            buf[1 + ISO8601_UTC_LEN] = ']';
            buf[1 + ISO8601_UTC_LEN + 1] = ' ';
            break :blk TEXT_ISO8601_UTC_PREFIX_LEN;
        },
    };
}
