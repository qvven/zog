# Architecture

`zog` is organized around a small logger core with focused internal modules.
Public API types live in `src/zog.zig`; implementation details stay under
`src/internal/`.

## Public Entry Point

- `src/zog.zig` defines public configuration, levels, stats, sink interfaces,
  and `make(cfg)`.
- `make(cfg)` validates comptime configuration and delegates construction to
  `src/internal/logger.zig`.

## Logger Core

- `src/internal/logger.zig` owns the concrete logger type produced by
  `zog.make`.
- It is responsible for level filtering, scope handling, mutex ownership,
  prefix/field dispatch, line formatting, and output fan-out.
- `emitLine()` is the only output fan-out point. It writes in this order:
  stderr, file, then extra sinks.
- File sink errors are converted into `Stats.file_write_errors` and
  `Stats.dropped_lines` by `logger.zig`; sink modules do not own public stats.

## Formatting

- `src/internal/format.zig` formats text and JSON lines into the logger's
  reusable line buffer.
- `src/internal/fields.zig` contains comptime helpers for distinguishing
  format arguments from structured key/value fields and for merging logger
  prefixes.
- `src/internal/time.zig` contains fixed-width timestamp rendering helpers for
  log lines and rotated archive names.

## Built-In Sinks

- `src/internal/stderr_sink.zig` owns stderr output, ANSI color detection,
  color wrapping, flushing, and stderr buffer lifetime.
- `src/internal/file_sink.zig` owns file output, file buffer lifetime, flush
  policy, active file byte counting, and size-based rotation.
- `src/internal/rotation.zig` contains timestamped archive rename logic and
  collision suffix handling.
- `src/internal/memory_sink.zig` provides the public `MemorySink` helper used
  by examples and tests.

## Error Policy

- Stderr write failures are ignored; stderr is best-effort terminal output.
- File write, flush, and rotation failures are observable through existing
  file stats.
- Extra sink callbacks return `void`, so their failures are not observable by
  the logger.
- The logger never panics on sink delivery failures.

## Extension Rules

- Keep public API changes in `src/zog.zig`.
- Keep sink-specific state inside the sink module rather than `logger.zig`.
- Keep formatting decisions inside `format.zig`; sinks should receive an
  already formatted newline-terminated line.
- Do not add retention or deletion policy to file rotation; archive cleanup is
  intentionally left to users or external tools.
