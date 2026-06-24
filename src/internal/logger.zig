//! Logger implementation body. `zog.make` validates the config and delegates
//! here. Public types stay in `zog.zig`; `root` is that public module, giving
//! this file access to shared types without a circular import.

const std = @import("std");
const Io = std.Io;
const fmt_internal = @import("format.zig");
const fields_internal = @import("fields.zig");
const rotation_internal = @import("rotation.zig");

const ANSI_RESET = "\x1b[0m";
const SourceLocation = std.builtin.SourceLocation;

fn ansi(level: anytype) []const u8 {
    return switch (level) {
        .debug => "\x1b[90m", // dim gray
        .info => "\x1b[32m", // green
        .warn => "\x1b[33m", // yellow
        .err => "\x1b[31m", // red
    };
}

/// Builds the concrete logger struct for `cfg`. `root` is the `zog` module.
pub fn Make(comptime root: type, comptime cfg: root.Config) type {
    const Level = root.Level;
    const Sink = root.Sink;
    const Stats = root.Stats;

    return struct {
        const Self = @This();
        const Scope = cfg.Scope;

        fn effectiveMinLevel(comptime tag: Scope) Level {
            if (comptime @hasDecl(Scope, "minLevel")) {
                return Scope.minLevel(tag);
            }
            return cfg.min_level;
        }

        file: ?Io.File = null,
        file_writer: Io.File.Writer = undefined,
        file_writer_opened: bool = false,
        file_bytes: u64 = 0,
        stderr_file: Io.File = undefined,
        stderr_writer: Io.File.Writer = undefined,
        stderr_opened: bool = false,
        colorize: bool = false,
        extra_sinks: std.ArrayList(Sink) = .empty,
        mutex: Io.Mutex = .init,
        line_buf: []u8,
        gpa: std.mem.Allocator,
        io: Io,
        stats_data: Stats = .{},
        warned_file_error: bool = false,

        pub fn open(gpa: std.mem.Allocator, io: Io) !Self {
            const line_buf = try gpa.alloc(u8, cfg.max_line_bytes);
            errdefer gpa.free(line_buf);

            var self: Self = .{
                .line_buf = line_buf,
                .gpa = gpa,
                .io = io,
            };
            errdefer self.cleanupOpenFailure(io);

            if (comptime cfg.stderr) {
                // Size the stderr buffer to hold a full line (plus a little
                // slack for the ANSI color wrap) so a typical line drains in
                // one write rather than several. A line can still exceed this;
                // `writeAll` just drains in multiple passes then.
                const stderr_buf_len = cfg.max_line_bytes + 16;
                const stderr_buf = try gpa.alloc(u8, stderr_buf_len);
                self.stderr_file = Io.File.stderr();
                self.stderr_writer = self.stderr_file.writer(io, stderr_buf);
                self.stderr_opened = true;

                self.stderr_file.enableAnsiEscapeCodes(io) catch {};
                self.colorize = self.stderr_file.supportsAnsiEscapeCodes(io) catch false;
            }

            if (comptime cfg.file_path) |path| {
                const f = try Io.Dir.cwd().createFile(io, path, .{
                    .truncate = false,
                    .read = true,
                });
                var file_owned = true;
                errdefer if (file_owned) f.close(io);
                const file_buf = try gpa.alloc(u8, cfg.file_buf_bytes);
                self.file = f;
                file_owned = false;
                self.file_writer = f.writer(io, file_buf);
                self.file_writer_opened = true;
                const end = f.length(io) catch 0;
                self.file_writer.seekTo(end) catch {};
                self.file_bytes = end;
            }

            return self;
        }

        pub fn close(self: *Self, io: Io) void {
            if (self.stderr_opened) {
                self.stderr_writer.interface.flush() catch {};
                self.gpa.free(self.stderr_writer.interface.buffer);
                self.stderr_opened = false;
            }
            if (self.file) |f| {
                self.file_writer.interface.flush() catch {};
                f.close(io);
            }
            if (self.file_writer_opened) {
                self.gpa.free(self.file_writer.interface.buffer);
                self.file_writer_opened = false;
            }
            self.extra_sinks.deinit(self.gpa);
            self.gpa.free(self.line_buf);
            self.* = undefined;
        }

        fn cleanupOpenFailure(self: *Self, io: Io) void {
            if (self.file) |f| {
                f.close(io);
                self.file = null;
            }
            if (self.file_writer_opened) {
                self.gpa.free(self.file_writer.interface.buffer);
                self.file_writer_opened = false;
            }
            if (self.stderr_opened) {
                self.gpa.free(self.stderr_writer.interface.buffer);
                self.stderr_opened = false;
            }
        }

        /// Adds an extra sink. Takes the mutex (when `thread_safe`) because
        /// `logScoped` iterates `extra_sinks` under it; appending without the
        /// lock could race with a concurrent log call and reallocate the
        /// backing slice mid-iteration.
        pub fn addSink(self: *Self, sink: Sink) !void {
            if (comptime cfg.thread_safe) self.mutex.lockUncancelable(self.io);
            defer if (comptime cfg.thread_safe) self.mutex.unlock(self.io);
            try self.extra_sinks.append(self.gpa, sink);
        }

        /// Flush buffered output to the underlying handles. Only meaningful
        /// under `.buffered`/`.on_level`, where file writes may sit in the
        /// write buffer; call before exit or periodically to bound data loss
        /// on a crash. `close()` flushes too. Cheap and safe to call anytime.
        pub fn flush(self: *Self) void {
            if (comptime cfg.thread_safe) self.mutex.lockUncancelable(self.io);
            defer if (comptime cfg.thread_safe) self.mutex.unlock(self.io);
            if (self.stderr_opened) self.stderr_writer.interface.flush() catch {};
            if (self.file != null) {
                self.file_writer.interface.flush() catch self.recordFileError();
            }
        }

        fn writeFileLine(self: *Self, line: []const u8, do_flush: bool) void {
            if (self.file == null) return;

            const w = &self.file_writer.interface;
            w.writeAll(line) catch {
                self.recordFileError();
                return;
            };
            if (do_flush) {
                w.flush() catch {
                    self.recordFileError();
                    return;
                };
            }
            self.file_bytes += line.len;
            switch (comptime cfg.file_rotation) {
                .none => {},
                .size => |rotation| {
                    if (self.file_bytes >= rotation.max_bytes) {
                        self.rotateFile() catch self.recordFileError();
                    }
                },
            }
        }

        fn rotateFile(self: *Self) !void {
            const path = comptime cfg.file_path orelse unreachable;
            try self.file_writer.interface.flush();
            if (self.file) |f| {
                f.close(self.io);
                self.file = null;
            }
            errdefer self.reopenFile(false) catch {};

            var scratch: [rotation_internal.timestampedScratchLen(path.len)]u8 = undefined;
            const now = Io.Clock.now(.real, self.io).toMilliseconds();
            try rotation_internal.rotateTimestamped(self.io, Io.Dir.cwd(), path, now, &scratch);
            try self.reopenFile(true);
        }

        fn reopenFile(self: *Self, comptime truncate: bool) !void {
            const path = comptime cfg.file_path orelse unreachable;
            const f = try Io.Dir.cwd().createFile(self.io, path, .{
                .truncate = truncate,
                .read = true,
            });
            errdefer f.close(self.io);
            self.file = f;
            self.file_writer = f.writer(self.io, self.file_writer.interface.buffer);
            self.file_bytes = if (truncate) 0 else f.length(self.io) catch 0;
            if (!truncate) self.file_writer.seekTo(self.file_bytes) catch {};
        }

        fn recordFileError(self: *Self) void {
            self.stats_data.file_write_errors += 1;
            self.stats_data.dropped_lines += 1;
            if (!self.warned_file_error and self.stderr_opened) {
                self.warned_file_error = true;
                const w = &self.stderr_writer.interface;
                w.writeAll("zog: file sink write failed; further errors will be counted in stats() but not reprinted\n") catch {};
                w.flush() catch {};
            }
        }

        /// Snapshot delivery counters as a value copy. If other threads may
        /// log concurrently and you need cross-field consistency, guard calls
        /// with external synchronization.
        pub fn stats(self: *Self) Stats {
            if (comptime cfg.thread_safe) self.mutex.lockUncancelable(self.io);
            defer if (comptime cfg.thread_safe) self.mutex.unlock(self.io);
            return self.stats_data;
        }

        /// Routes the trailing `payload` to either format args or kv fields
        /// based on whether it is a positional tuple or a named struct.
        inline fn dispatch(
            self: *Self,
            comptime tag: Scope,
            comptime level: Level,
            comptime src: ?SourceLocation,
            comptime fmt: []const u8,
            prefix: anytype,
            payload: anytype,
        ) void {
            if (comptime fields_internal.isFmtArgs(@TypeOf(payload))) {
                self.logScoped(tag, level, src, fmt, payload, prefix, .{});
            } else {
                self.logScoped(tag, level, src, fmt, .{}, prefix, payload);
            }
        }

        /// Logs at `debug`. The trailing argument is either format args
        /// (`.{ x, y }`) or structured kv fields (`.{ .key = value }`).
        pub inline fn debug(self: *Self, comptime fmt: []const u8, payload: anytype) void {
            self.dispatch(.default, .debug, null, fmt, .{}, payload);
        }
        pub inline fn info(self: *Self, comptime fmt: []const u8, payload: anytype) void {
            self.dispatch(.default, .info, null, fmt, .{}, payload);
        }
        pub inline fn warn(self: *Self, comptime fmt: []const u8, payload: anytype) void {
            self.dispatch(.default, .warn, null, fmt, .{}, payload);
        }
        pub inline fn err(self: *Self, comptime fmt: []const u8, payload: anytype) void {
            self.dispatch(.default, .err, null, fmt, .{}, payload);
        }

        /// Returns a logger bound to `src` for one or more calls:
        /// `log.at(@src()).info("...", .{});`
        pub inline fn at(self: *Self, comptime src: SourceLocation) AtLogger(.default, src) {
            return .{ .parent = self };
        }

        /// Returns a logger that prefixes every emit with `prefix` fields.
        /// The prefix is captured by value; pointers it carries must outlive
        /// the returned logger.
        ///
        /// Example: `const ctx = log.with(.{ .request_id = id }); ctx.info("...", .{});`
        pub inline fn with(self: *Self, prefix: anytype) WithLogger(@TypeOf(prefix), .default, null) {
            return .{ .parent = self, .prefix = prefix };
        }

        /// Returns a logger bound to `tag`.
        pub fn scope(self: *Self, comptime tag: Scope) Scoped(tag) {
            return .{ .parent = self };
        }

        fn AtLogger(comptime tag: Scope, comptime src: SourceLocation) type {
            return struct {
                parent: *Self,
                pub inline fn debug(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .debug, src, fmt, .{}, payload);
                }
                pub inline fn info(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .info, src, fmt, .{}, payload);
                }
                pub inline fn warn(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .warn, src, fmt, .{}, payload);
                }
                pub inline fn err(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .err, src, fmt, .{}, payload);
                }
                pub inline fn with(s: @This(), prefix: anytype) WithLogger(@TypeOf(prefix), tag, src) {
                    return .{ .parent = s.parent, .prefix = prefix };
                }
            };
        }

        fn WithLogger(comptime P: type, comptime tag: Scope, comptime src: ?SourceLocation) type {
            return struct {
                parent: *Self,
                prefix: P,
                pub inline fn debug(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .debug, src, fmt, s.prefix, payload);
                }
                pub inline fn info(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .info, src, fmt, s.prefix, payload);
                }
                pub inline fn warn(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .warn, src, fmt, s.prefix, payload);
                }
                pub inline fn err(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .err, src, fmt, s.prefix, payload);
                }
                /// Bind a source location on top of this WithLogger.
                pub inline fn at(s: @This(), comptime new_src: SourceLocation) WithLogger(P, tag, new_src) {
                    return .{ .parent = s.parent, .prefix = s.prefix };
                }
                /// Extend the prefix with more fields. The new logger contains
                /// a merged struct so emits include both the old and new fields.
                pub inline fn with(s: @This(), more: anytype) WithLogger(fields_internal.MergedPrefix(P, @TypeOf(more)), tag, src) {
                    return .{
                        .parent = s.parent,
                        .prefix = fields_internal.mergePrefix(s.prefix, more),
                    };
                }
            };
        }

        fn Scoped(comptime tag: Scope) type {
            return struct {
                parent: *Self,
                pub inline fn debug(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .debug, null, fmt, .{}, payload);
                }
                pub inline fn info(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .info, null, fmt, .{}, payload);
                }
                pub inline fn warn(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .warn, null, fmt, .{}, payload);
                }
                pub inline fn err(s: @This(), comptime fmt: []const u8, payload: anytype) void {
                    s.parent.dispatch(tag, .err, null, fmt, .{}, payload);
                }
                pub inline fn at(s: @This(), comptime src: SourceLocation) AtLogger(tag, src) {
                    return .{ .parent = s.parent };
                }
                pub inline fn with(s: @This(), prefix: anytype) WithLogger(@TypeOf(prefix), tag, null) {
                    return .{ .parent = s.parent, .prefix = prefix };
                }
            };
        }

        fn logScoped(
            self: *Self,
            comptime scope_tag: Scope,
            comptime level: Level,
            comptime src: ?SourceLocation,
            comptime fmt: []const u8,
            args: anytype,
            prefix_fields: anytype,
            fields: anytype,
        ) void {
            if (comptime @intFromEnum(level) < @intFromEnum(effectiveMinLevel(scope_tag))) return;

            if (comptime cfg.thread_safe) self.mutex.lockUncancelable(self.io);
            defer if (comptime cfg.thread_safe) self.mutex.unlock(self.io);

            const line = switch (comptime cfg.format) {
                .text => fmt_internal.formatText(self.line_buf, cfg.timestamp, cfg.source, scope_tag, level, src, fmt, args, prefix_fields, fields, self.io),
                .json => fmt_internal.formatJson(self.line_buf, cfg.timestamp, cfg.source, scope_tag, level, src, fmt, args, prefix_fields, fields, self.io),
            };

            if (comptime cfg.stderr) {
                const w = &self.stderr_writer.interface;
                if (self.colorize) {
                    w.writeAll(ansi(level)) catch {};
                    w.writeAll(line) catch {};
                    w.writeAll(ANSI_RESET) catch {};
                } else {
                    w.writeAll(line) catch {};
                }
                w.flush() catch {};
            }
            if (self.file != null) {
                // The flush decision is comptime-known per call site. Under
                // `.on_level`, calls below the threshold compile to buffered
                // writes with no runtime branch.
                const flush_file = comptime switch (cfg.flush_policy) {
                    .every_line => true,
                    .buffered => false,
                    .on_level => @intFromEnum(level) >= @intFromEnum(cfg.flush_on_level),
                };
                self.writeFileLine(line, flush_file);
            }
            for (self.extra_sinks.items) |sink| {
                sink.vtable.write(sink.ptr, level, @tagName(scope_tag), line);
            }
        }
    };
}
