const std = @import("std");
const Io = std.Io;
const time = @import("time.zig");

pub fn timestampedScratchLen(path_len: usize) usize {
    return path_len + 1 + time.ARCHIVE_TIMESTAMP_LEN + 4;
}

pub fn rotateTimestamped(io: Io, cwd: Io.Dir, path: []const u8, epoch_ms: i64, scratch: []u8) !void {
    if (scratch.len < timestampedScratchLen(path.len)) return error.NoSpaceLeft;

    var stamp: [time.ARCHIVE_TIMESTAMP_LEN]u8 = undefined;
    time.formatArchiveTimestamp(&stamp, epoch_ms);

    const base = std.fmt.bufPrint(scratch, "{s}.{s}", .{ path, &stamp }) catch return error.NoSpaceLeft;
    if (!fileExists(io, cwd, base)) {
        try cwd.rename(path, cwd, base, io);
        return;
    }

    var seq: u16 = 1;
    while (seq <= 999) : (seq += 1) {
        const target = std.fmt.bufPrint(scratch, "{s}.{s}.{d:0>3}", .{ path, &stamp, seq }) catch return error.NoSpaceLeft;
        if (!fileExists(io, cwd, target)) {
            try cwd.rename(path, cwd, target, io);
            return;
        }
    }

    return error.TooManyArchiveCollisions;
}

fn fileExists(io: Io, cwd: Io.Dir, path: []const u8) bool {
    const f = cwd.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}
