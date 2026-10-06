# zig-iso8583

High-performance ISO 8583 parser/serializer in [Zig](https://ziglang.org/).

## Features

- **Zero-copy decode** — Decoded fields are `[]const u8` slices into the source buffer; no data copying during parse
- **SIMD-accelerated** — Bitmap scanning, ASCII digit/alphanumeric validation, BCD↔ASCII conversion, memchr — all using `@Vector` with scalar fallbacks
- **ArenaAllocator** — Per-message arena with bulk `deinit()` or `reset()` for server loops; ≤2 heap allocations per message
- **Comptime spec DSL** — Message specifications are defined at comptime; field dispatch is monomorphized (no hash maps), version-specific branches are eliminated
- **Pre-built specs** — ISO 8583:1987, 1993, and 2003 specifications included
- **Round-trip guaranteed** — `encode(decode(msg))` produces byte-identical output

## Performance

Benchmarks on a typical machine (ReleaseFast):

```
Decode:   ~1.3M msg/sec  (~735 ns/msg)
Encode:   ~710K msg/sec  (~1409 ns/msg)
```

## Quick Start

### Decode

```zig
const iso8583 = @import("iso8583");

// Use a pre-built spec
const spec = &iso8583.SpecV1987;

var msg = try iso8583.Message.init(allocator, spec);
defer msg.deinit();
try msg.decode(raw_bytes);

const pan = msg.getField(2);      // → ?[]const u8 (zero-copy)
const amount = msg.getFieldInt(4); // → ?u64 (pre-parsed)
```

### Encode

```zig
var msg = try iso8583.Message.init(allocator, spec);
defer msg.deinit();

iso8583.setMti(&msg, 0, .authorization, .request, .acquirer);
try iso8583.setField(&msg, 2, "4111111111111111");
try iso8583.setField(&msg, 3, "000000");
try iso8583.setField(&msg, 4, "000000001000");

var buf = std.ArrayList(u8).init(allocator);
try iso8583.encode(&msg, buf.writer());
const wire_bytes = buf.items;
```

### Custom Spec

```zig
const MySpec = comptime iso8583.Spec.define(.{
    .version = .v1987,
    .fields = &.{
        iso8583.field.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        iso8583.field.field(3, .fixed_6, .ascii_numeric, .{}),
        iso8583.field.field(4, .fixed_12, .ascii_numeric, .{}),
        iso8583.field.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
    },
});
```

## Building

```bash
# Run tests
zig build test

# Run benchmarks (ReleaseFast)
zig build bench

# Run example
zig build example

# Build static library
zig build
```

## API Reference

### Types

| Type | Description |
|------|-------------|
| `Message` | Decoded ISO 8583 message with arena allocator |
| `Spec` | Comptime message specification |
| `Bitmap` | 128-bit bitmap with SIMD popcount |
| `Mti` | Message Type Identifier |
| `FieldView` | Zero-copy view of a decoded field |
| `FieldStore` | Field storage with direct-index access |

### Spec Definitions

| Spec | Description |
|------|-------------|
| `SpecV1987` | ISO 8583:1987 — 50+ common fields |
| `SpecV1993` | ISO 8583:1993 — updated fields |
| `SpecV2003` | ISO 8583:2003 — new fields and formats |

### Field Encodings

| Encoding | Description |
|----------|-------------|
| `ascii_numeric` | ASCII digits '0'–'9' |
| `ascii_alpha` | ASCII alphanumeric |
| `ascii_binary` | ASCII hex representation |
| `bcd` | Binary Coded Decimal |
| `binary` | Raw bytes |

### Length Types

| Type | Description |
|------|-------------|
| `fixed_N` | Fixed-length (N bytes) |
| `llvar` | 2-digit length prefix |
| `lllvar` | 3-digit length prefix |
| `llllvar` | 4-digit length prefix |

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  zig-iso8583                      │
├────────────┬────────────┬────────────────────────┤
│  comptime  │  runtime   │        simd            │
│ spec engine│ parse/emit │ bitmap/validate/search │
├────────────┴────────────┴────────────────────────┤
│              zero-copy slice views                │
├──────────────────────────────────────────────────┤
│          ArenaAllocator (per-message)             │
└──────────────────────────────────────────────────┘
```

## License

MIT
