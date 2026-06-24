# zog

A comptime-first logging library for Zig 0.16.

```zig
const zog = @import("zog");

const Logger = zog.make(.{ .min_level = .info });
var log = try Logger.open(gpa, io);
defer log.close(io);

log.info("hello {s}", .{"world"});
log.warn("disk {d}% full", .{92});
```

## Features

- **Comptime-erased filtering** - calls below the level threshold emit no code
  and no string data.
- **Scopes** - name independent lanes (`server` vs `admin`), each with its own
  compile-time level threshold. Typos fail to compile.
- **Context fields** - `with(.{ .user = id })` attaches runtime data to every
  line; chain to accumulate more as the call goes deeper.
- **Structured kv fields** - pass named fields (`.{ .uid = 42 }`) as the
  trailing argument; the message and the data stay separate.
- **Text and NDJSON** - human-readable lines or aggregator-ready JSON with
  correct string escaping.
- **Multiple sinks** - built-in stderr (with auto color detection) and file,
  plus a `Sink` vtable for anything else: memory, syslog, network.
- **Tunable file flush and rotation** - flush every line, buffer, flush on
  level, or archive the file when it reaches a size cap.
- **Thread-safe** - optional internal mutex.

See [`examples/`](examples/) for runnable usage of each:

- [`basic.zig`](examples/basic.zig) - text logs with format args.
- [`file_rotation.zig`](examples/file_rotation.zig) - size-based file rotation.
- [`json.zig`](examples/json.zig) - NDJSON output with structured fields.
- [`scopes.zig`](examples/scopes.zig) - per-scope levels and compile-time filtering.
- [`structured.zig`](examples/structured.zig) - JSON kv fields with enum and optional values.

## Installation

Add zog to your project:

```sh
zig fetch --save https://github.com/qvven/zog/archive/refs/tags/v0.2.0.tar.gz
```

Then import the package module from your `build.zig`:

```zig
const zog_dep = b.dependency("zog", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zog", zog_dep.module("zog"));
```

Until a public release URL exists, local development can use a path dependency
in `build.zig.zon`:

```zig
.dependencies = .{
    .zog = .{ .path = "../zog" },
},
```

## Configuration reference

```zig
pub const Config = struct {
    min_level: Level = .info,                  // global minimum level
    Scope: type = NoScope,                     // user-defined enum, must have .default
    timestamp: TimestampFormat = .iso8601_utc, // .iso8601_utc | .unix_ms | .none
    format: LineFormat = .text,                // .text | .json
    source: SourceMode = .none,                // .none | .file_line
    stderr: bool = true,
    file_path: ?[]const u8 = null,
    file_rotation: FileRotation = .none,       // .none | .{ .size = .{ .max_bytes = n } }
    flush_policy: FlushPolicy = .every_line,   // .every_line | .buffered | .on_level
    flush_on_level: Level = .warn,             // .on_level flush threshold
    file_buf_bytes: usize = 4096,              // file sink write buffer
    max_line_bytes: usize = 1024,              // single-line cap
    thread_safe: bool = true,                  // enable internal mutex
};
```

## Development

Build the demo executable:

```sh
zig build
```

Run tests:

```sh
zig build test
```

Run the full local check, including examples:

```sh
zig build check
```

Tested on Zig 0.16.0.
