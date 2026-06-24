pub const std = @import("std");

pub const testing = std.testing;

pub const zog = @import("../../zog.zig");

pub const Level = zog.Level;

pub const MemorySink = zog.MemorySink;

pub const make = zog.make;

pub const time_internal = @import("../time.zig");

pub const rotation_internal = @import("../rotation.zig");

pub fn parseJsonLine(gpa: std.mem.Allocator, line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, std.mem.trimEnd(u8, line, "\n"), .{});
}

pub fn expectJsonString(obj: anytype, key: []const u8, expected: []const u8) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    switch (value) {
        .string => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

pub fn expectJsonInteger(obj: anytype, key: []const u8, expected: i64) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    switch (value) {
        .integer => |actual| try testing.expectEqual(expected, actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

pub fn expectJsonBool(obj: anytype, key: []const u8, expected: bool) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    switch (value) {
        .bool => |actual| try testing.expectEqual(expected, actual),
        else => return error.UnexpectedJsonFieldType,
    }
}

pub fn expectJsonNull(obj: anytype, key: []const u8) !void {
    const value = obj.get(key) orelse return error.MissingJsonField;
    try testing.expect(value == .null);
}

pub fn openCloseNoFile(gpa: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    const Logger = make(.{
        .stderr = true,
        .timestamp = .none,
    });
    var log = try Logger.open(gpa, io);
    defer log.close(io);
}

pub const DropSink = struct {
    count: usize = 0,

    pub fn sink(self: *DropSink) zog.Sink {
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

pub fn deleteLogFiles(io: std.Io, cwd: std.Io.Dir, path: []const u8) void {
    cwd.deleteFile(io, path) catch {};
}

pub fn deleteLogFamily(io: std.Io, cwd: std.Io.Dir, path: []const u8) void {
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

pub fn writeWholeFile(io: std.Io, cwd: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [64]u8 = undefined;
    var writer = f.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn findSingleArchive(io: std.Io, cwd: std.Io.Dir, path: []const u8, out: []u8) !?[]const u8 {
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
pub fn readLogFileAlloc(io: std.Io, cwd: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
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

pub fn fileSize(io: std.Io, cwd: std.Io.Dir, path: []const u8) !u64 {
    const f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    return f.length(io);
}

pub fn openCloseWithFile(gpa: std.mem.Allocator) !void {
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
