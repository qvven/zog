const std = @import("std");
const root = @import("../zog.zig");

const Level = root.Level;
const Sink = root.Sink;

/// A sink that captures every line in memory. Intended for tests and for
/// short-lived in-process inspection. It never frees individual lines, so a
/// long-running process should not point a `MemorySink` at it unbounded.
///
/// Lifetime of returned views:
///   - `bytes()` and every `Entry.line` returned by `entries()` /
///     `entriesAlloc()` point into the internal byte buffer. A later log call
///     can grow and reallocate that buffer, invalidating previously returned
///     slices. Read them before logging again, or copy what you need.
///   - `entries()` returns a snapshot cached inside the sink. Each call frees
///     the previous snapshot and returns a fresh one, so only the most recent
///     return value is valid; read or copy it before calling `entries()`
///     again. For an independently owned snapshot that you free yourself, use
///     `entriesAlloc`.
pub const MemorySink = struct {
    gpa: std.mem.Allocator,
    bytes_buf: std.ArrayList(u8) = .empty,
    /// Each log gets one RawEntry. It stores offset + len into bytes_buf so
    /// realloc cannot invalidate previously returned metadata.
    raw_entries: std.ArrayList(RawEntry) = .empty,
    entries_cache: ?[]Entry = null,

    pub const Entry = struct {
        level: Level,
        scope_name: []const u8,
        line: []const u8,
    };

    const RawEntry = struct {
        level: Level,
        scope_name: []const u8,
        offset: usize,
        len: usize,
    };

    pub fn init(gpa: std.mem.Allocator) MemorySink {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemorySink) void {
        if (self.entries_cache) |cache| self.gpa.free(cache);
        self.bytes_buf.deinit(self.gpa);
        self.raw_entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn sink(self: *MemorySink) Sink {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// All captured bytes, concatenated. Borrowed: a later log call may
    /// reallocate the backing buffer and invalidate this slice.
    pub fn bytes(self: *const MemorySink) []const u8 {
        return self.bytes_buf.items;
    }

    /// Snapshot the entries into a caller-owned slice (caller frees). The
    /// returned `Entry.line` slices still point into the sink's byte buffer,
    /// so they remain subject to invalidation on the next log call. Copy the
    /// line bytes too if they must outlive further logging.
    pub fn entriesAlloc(self: *const MemorySink, gpa: std.mem.Allocator) ![]Entry {
        const out = try gpa.alloc(Entry, self.raw_entries.items.len);
        errdefer gpa.free(out);
        for (self.raw_entries.items, 0..) |re, i| {
            out[i] = .{
                .level = re.level,
                .scope_name = re.scope_name,
                .line = self.bytes_buf.items[re.offset..][0..re.len],
            };
        }
        return out;
    }

    /// Snapshot cached inside the sink. Each call frees the previous snapshot,
    /// so only the most recent return value is valid; read or copy it before
    /// calling again. Not synchronized: if the logger is `thread_safe` and may
    /// be writing from another thread, call this only while logging is quiesced
    /// or under your own external lock.
    pub fn entries(self: *MemorySink) []Entry {
        if (self.entries_cache) |cache| self.gpa.free(cache);
        const out = self.entriesAlloc(self.gpa) catch {
            self.entries_cache = null;
            return &[_]Entry{};
        };
        self.entries_cache = out;
        return out;
    }

    pub fn count(self: *const MemorySink) usize {
        return self.raw_entries.items.len;
    }

    const vtable: Sink.VTable = .{ .write = writeImpl };

    fn writeImpl(ptr: *anyopaque, level: Level, scope_name: []const u8, line: []const u8) void {
        const self: *MemorySink = @ptrCast(@alignCast(ptr));
        const offset = self.bytes_buf.items.len;
        self.bytes_buf.appendSlice(self.gpa, line) catch return;
        self.raw_entries.append(self.gpa, .{
            .level = level,
            .scope_name = scope_name,
            .offset = offset,
            .len = line.len,
        }) catch return;
    }
};
