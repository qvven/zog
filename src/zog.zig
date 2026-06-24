//! zog - a comptime-first logging library for Zig 0.16.
//!
//! See README for examples and configuration details.

const std = @import("std");
const Io = std.Io;
const memory_sink = @import("internal/memory_sink.zig");
const logger_internal = @import("internal/logger.zig");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Default scope type.
pub const NoScope = enum { default };

/// Timestamp rendering mode.
pub const TimestampFormat = enum { iso8601_utc, unix_ms, none };

/// Line output format.
pub const LineFormat = enum { text, json };

/// Source location rendering mode.
pub const SourceMode = enum { none, file_line };

/// When the file sink flushes to disk. Only affects the file sink; stderr
/// always flushes per line so terminal output stays prompt.
pub const FlushPolicy = enum {
    /// Flush after every line (default). Safest: nothing is lost on a crash.
    every_line,
    /// Never flush per line; the file write buffer drains when full, on an
    /// explicit `flush()`, or on `close()`. Highest throughput, but buffered
    /// lines are lost if the process crashes before a flush.
    buffered,
    /// Buffer, but flush immediately when a line's level is at or above
    /// `Config.flush_on_level`. A middle ground: routine lines batch, while
    /// crash-adjacent warnings/errors are persisted.
    on_level,
};

/// Extra sink interface. The caller owns sink lifetime.
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Receives one newline-terminated formatted line without ANSI color.
        ///
        /// Lifetime: `line` and `scope_name` are borrowed for this call only.
        /// `line` aliases the logger's internal buffer and is overwritten by
        /// the next log call, so copy it if it must be retained. `scope_name`
        /// is backed by a static enum tag name, but callers should still treat
        /// it as borrowed.
        ///
        /// Reentrancy: when `thread_safe` is enabled (the default), this
        /// callback runs while the logger's mutex is held. It must not call
        /// back into the same logger; log/flush/addSink/stats would deadlock
        /// because the mutex is not recursive. Keep the callback short and
        /// non-blocking.
        write: *const fn (
            ptr: *anyopaque,
            level: Level,
            scope_name: []const u8,
            line: []const u8,
        ) void,
    };
};

pub const MemorySink = memory_sink.MemorySink;

/// Counters for delivery failures the logger can observe.
pub const Stats = struct {
    /// Total log calls where at least one observed delivery failed.
    dropped_lines: u64 = 0,
    /// File writer or flush errors.
    file_write_errors: u64 = 0,
};

pub const Config = struct {
    /// Global minimum level.
    min_level: Level = .info,
    /// Scope enum. Must contain `.default`; may define `minLevel(tag)`.
    Scope: type = NoScope,
    /// Timestamp mode.
    timestamp: TimestampFormat = .iso8601_utc,
    /// Line format.
    format: LineFormat = .text,
    /// Source location mode.
    source: SourceMode = .none,
    /// Enable stderr output.
    stderr: bool = true,
    /// Optional log file path.
    file_path: ?[]const u8 = null,
    /// When the file sink flushes to disk. Does not affect stderr.
    flush_policy: FlushPolicy = .every_line,
    /// Level threshold that forces a flush under `.on_level`.
    flush_on_level: Level = .warn,
    /// Size of the file sink's write buffer. Larger buffers batch more writes
    /// under `.buffered`/`.on_level`, reducing syscalls.
    file_buf_bytes: usize = 4096,
    /// Maximum formatted line length.
    max_line_bytes: usize = 1024,
    /// Protect formatting and sink writes with an internal mutex.
    thread_safe: bool = true,
};

/// Returns a logger type specialized by `cfg`.
pub fn make(comptime cfg: Config) type {
    comptime {
        const info = @typeInfo(cfg.Scope);
        if (info != .@"enum") @compileError("zog: Config.Scope must be an enum");
        if (!@hasField(cfg.Scope, "default")) {
            @compileError("zog: Scope enum must have a `default` tag");
        }

        if (cfg.file_path) |_| {
            if (cfg.file_buf_bytes < 64)
                @compileError("zog: file_buf_bytes must be at least 64");
        }
    }

    return logger_internal.Make(@This(), cfg);
}

test "zog behavior" {
    _ = @import("internal/tests.zig");
}
