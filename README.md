# zig-iso8583

**High-performance ISO 8583 parser/serializer written in [Zig](https://ziglang.org/).**

Built with advanced Zig features: SIMD vectorization, zero-copy parsing,
arena allocation, and comptime metaprogramming.

```zig
const iso8583 = @import("iso8583");

var msg = try iso8583.Message.init(allocator, &iso8583.SpecV1987);
defer msg.deinit();
try msg.decode(wire_bytes);

const pan = msg.getField(2).?;      // zero-copy — no allocation
const amount = msg.getFieldInt(4);  // pre-parsed integer
```

---

## Table of Contents

- [Features](#features)
- [Performance](#performance)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [Decoding a Message](#decoding-a-message)
  - [Encoding a Message](#encoding-a-message)
  - [Round-Trip](#round-trip)
  - [Custom Specs](#custom-specs)
  - [Message Reuse in Server Loops](#message-reuse-in-server-loops)
- [API Reference](#api-reference)
  - [Message](#message)
  - [Spec](#spec)
  - [Field Encodings](#field-encodings)
  - [Length Types](#length-types)
  - [MTI](#mti)
  - [Bitmap](#bitmap)
  - [SIMD Utilities](#simd-utilities)
  - [Validation](#validation)
  - [Error Sets](#error-sets)
- [ISO 8583 Primer](#iso-8583-primer)
  - [Message Structure](#message-structure)
  - [Bitmap Layout](#bitmap-layout)
  - [Field Format Examples](#field-format-examples)
- [Architecture](#architecture)
- [Design Pillars](#design-pillars)
- [Testing](#testing)
- [Project Layout](#project-layout)
- [License](#license)

---

## Features

| Feature | Description |
|---------|-------------|
| **Zero-copy decode** | Decoded fields are `[]const u8` slices into the source buffer — parsing never copies field data |
| **SIMD-accelerated** | Bitmap scanning, ASCII digit/alnum validation, BCD↔ASCII conversion, and memchr use `@Vector` intrinsics (SSE/AVX on x86-64, NEON on ARM) |
| **Arena allocation** | Each message owns an `ArenaAllocator`; one `deinit()` frees everything, `reset()` reuses capacity for server loops |
| **Comptime spec DSL** | Message specs are compile-time constants; field dispatch is monomorphized with direct-index lookup — no hash maps anywhere |
| **Strict spec validation** | Duplicate field IDs, out-of-range IDs, and variable-length fields without `max_len` are **compile errors** (`Spec.define`) |
| **Unknown-field policy** | Fields set in the bitmap but missing from the spec are rejected by default (`error.FieldNotInSpec` + `msg.last_unknown_field`); opt into legacy skip behavior with `.unknown_fields = .skip` |
| **Field names** | Optional human-readable `.name` per field (all of `SpecV1987` is named) for logs and diagnostics — `spec.nameOf(id)`, `spec.writeFieldName(id, writer)` |
| **Transport framing** | `framing` module: strip/attach 5-byte TPDU or 12-byte B24-style headers and 2-byte big-endian length prefixes — the codec itself always starts at the MTI |
| **Pre-built specs** | ISO 8583:1987, 1993, and 2003 specifications included |
| **Round-trip guaranteed** | `encode(decode(bytes))` produces byte-identical output |
| **No hidden allocation** | Decode performs zero heap allocations; encode writes to any `*std.Io.Writer` |

## Performance

Measured with `zig build bench` (ReleaseFast, 75-byte authorization request, 1M iterations):

| Operation | Throughput | Per Message |
|-----------|-----------:|------------:|
| Decode | ~1.3M msg/sec | ~735 ns |
| Encode | ~710K msg/sec | ~1,409 ns |

Performance targets from the design document are met or exceeded
(> 1M msg/sec decode, > 800K msg/sec encode).

## Requirements

- Zig 0.16.0 or later

## Installation

### As a dependency (build.zig.zon)

```bash
zig fetch --save git+https://github.com/youruser/zig-iso8583
```

```zig
// build.zig
const iso8583 = b.dependency("zig_iso8583", .{});
exe.root_module.addImport("iso8583", iso8583.module("iso8583"));
```

### Local development

```bash
git clone <repo>
cd zig-iso8583
zig build test      # run all tests
zig build example   # run the basic example
zig build bench     # run benchmarks (ReleaseFast)
```

---

## Quick Start

### Decoding a Message

```zig
const std = @import("std");
const iso8583 = @import("iso8583");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Raw wire bytes: MTI 0100, fields 2, 3, 4
    const wire = "0100" ++ [_]u8{ 0x70, 0, 0, 0, 0, 0, 0, 0 } ++ "164111111111111111" ++ "000000" ++ "000000001000";

    // 1. Create a message bound to a spec
    var msg = try iso8583.Message.init(allocator, &iso8583.SpecV1987);
    defer msg.deinit();                          // one call frees everything

    // 2. Decode — fields become slices into `wire`
    try msg.decode(wire);

    // 3. Inspect
    std.debug.print("MTI: {f}\n", .{msg.mti});    // "0100"
    std.debug.print("Class: {}\n", .{msg.mti.class}); // .authorization

    if (msg.getField(2)) |pan|                   // zero-copy view
        std.debug.print("PAN: {s}\n", .{pan});   // "4111111111111111"

    if (msg.getFieldInt(4)) |amount|             // pre-parsed at decode time
        std.debug.print("Amount: {} cents\n", .{amount}); // 1000
}
```

### Encoding a Message

```zig
var msg = try iso8583.Message.init(allocator, &iso8583.SpecV1987);
defer msg.deinit();

// MTI: version=0 (1987), financial request from acquirer → "0200"
iso8583.setMti(&msg, 0, .financial, .request, .acquirer);

// Fields — validated against the spec at set time
try iso8583.setField(&msg, 2, "4111111111111111");   // PAN (llvar → prefix "16")
try iso8583.setField(&msg, 3, "000000");              // Processing code (fixed_6)
try iso8583.setField(&msg, 4, "000000001000");        // $10.00 (fixed_12)
try iso8583.setField(&msg, 41, "TERM0001");           // Terminal ID (fixed_8)
try iso8583.setField(&msg, 49, "840");                // Currency: USD (fixed_3)
try iso8583.setField(&msg, 52, &pin_block);           // PIN block (binary, 8 bytes)

// Serialize to any *std.Io.Writer (Allocating for heap output)
var buf = std.Io.Writer.Allocating.init(allocator);
defer buf.deinit();
try iso8583.encode(&msg, &buf.writer);
// buf.written() is the wire-format message
```

### Round-Trip

```zig
// Decode → Encode is byte-identical
try msg.decode(wire_bytes);

var out = std.Io.Writer.Allocating.init(allocator);
defer out.deinit();
try iso8583.encode(&msg, &out.writer);

try std.testing.expectEqualSlices(u8, wire_bytes, out.written()); // ✓
```

### Custom Specs

Define a spec at comptime — it becomes a compile-time constant and all
field dispatch is specialized against it:

```zig
const AcquirerSpec = iso8583.Spec.define(.{
    .version = .v1987,
    .mti_encoding = .ascii,       // 4 ASCII bytes (default)
    .bitmap_encoding = .binary,   // 8/16 raw bytes (default)
    .fields = &.{
        iso8583.field.field(2,  .llvar,   .ascii_numeric, .{ .max_len = 19 }), // PAN
        iso8583.field.field(3,  .fixed_6, .ascii_numeric, .{}),                 // Processing code
        iso8583.field.field(4,  .fixed_12,.ascii_numeric, .{}),                 // Amount
        iso8583.field.field(22, .fixed_3, .ascii_numeric, .{}),                 // POS entry mode
        iso8583.field.field(33, .llvar,   .ascii_numeric, .{ .max_len = 11 }),  // Forwarding inst.
        iso8583.field.field(48, .lllvar,  .ascii_alpha,   .{ .max_len = 999 }), // Additional data
        iso8583.field.field(52, .fixed_8, .binary,        .{}),                 // PIN block
        iso8583.field.field(55, .lllvar,  .binary,        .{ .max_len = 999 }), // ICC data
        iso8583.field.field(64, .fixed_8, .binary,        .{}),                 // MAC
    },
});

var msg = try iso8583.Message.init(allocator, &AcquirerSpec);
```

Fields not in the spec that appear in a message bitmap are skipped during
decode — this makes specs forward-compatible with network-specific extensions.

### Message Reuse in Server Loops

`reset()` clears fields while retaining the arena's capacity — ideal for
high-throughput servers:

```zig
var msg = try iso8583.Message.init(allocator, &iso8583.SpecV1987);
defer msg.deinit();

while (true) {
    const wire = readMessage(connection);
    msg.reset();                    // keep arena capacity, clear state
    try msg.decode(wire);
    try handle(&msg);
    // no per-message allocation churn
}
```

---

## API Reference

### Message

`Message` is the central type — a decoded ISO 8583 message.

| Signature | Description |
|-----------|-------------|
| `init(backing: Allocator, spec: *const Spec) !Message` | Create a message bound to a comptime spec |
| `deinit(self: *Message) void` | Free all memory (arena) |
| `reset(self: *Message) void` | Clear state, keep arena capacity |
| `decode(self: *Message, buf: []const u8) !void` | Parse wire bytes (zero-copy) |
| `getField(self, field_id: usize) ?[]const u8` | Raw field data (zero-copy view) |
| `getFieldInt(self, field_id: usize) ?u64` | Pre-parsed integer (numeric fields ≤ 19 digits) |
| `isPresent(self, field_id: usize) bool` | Field presence check |
| `fieldCount(self) usize` | Number of present fields |
| `fieldIterator(self) FieldStore.Iterator` | Iterate present field IDs ascending |

Public data fields: `mti: Mti`, `bitmap: Bitmap`, `spec: *const Spec`,
`last_unknown_field: ?u8` (set when decode hit a bitmap field missing from
the spec — see `UnknownFieldPolicy`).

**Lifetime contract:** field slices reference the buffer passed to `decode()`.
Keep that buffer alive and unmodified while the message is in use.

### Spec

| Signature | Description |
|-----------|-------------|
| `Spec.define(comptime config: SpecConfig) Spec` | Build a spec at comptime (validates the field set — see below) |
| `spec.lookup(field_id: usize) ?FieldDescriptor` | O(1) descriptor lookup |
| `spec.hasField(field_id: usize) bool` | Field defined in spec? |
| `spec.fieldCount() usize` | Number of fields in spec |
| `spec.mtiLen() usize` | MTI wire length (4 ASCII / 2 BCD) |
| `spec.bitmapLen() usize` | Min bitmap length (8 binary / 16 BCD) |
| `spec.nameOf(field_id: usize) ?[]const u8` | Field's `.name`, or null (fallback label: `"DE<id>"`) |
| `spec.writeFieldName(field_id, writer) !void` | Write name or `"DE<id>"` — for unambiguous logs |
| `spec.unknown_fields` | `UnknownFieldPolicy` — `.reject` (default) or `.skip` |

`SpecConfig` fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `version` | `Version` | required | `.v1987`, `.v1993`, `.v2003` |
| `mti_encoding` | `MtiEncoding` | `.ascii` | `.ascii` or `.bcd` |
| `bitmap_encoding` | `BitmapEncoding` | `.binary` | `.binary` or `.bcd` |
| `fields` | `[]const FieldDescriptor` | required | Field definitions |
| `unknown_fields` | `UnknownFieldPolicy` | `.reject` | Behavior for bitmap fields not in the spec |

**Comptime validation.** `Spec.define` is a compile error if the field set
contains an out-of-range ID (not 2–128), a duplicate ID, or a variable-length
field without `max_len`. Misconfigured dialects fail the build, not production.
Detection logic is also callable at runtime via `firstInvalidField(fields)`
(returning a `FieldProblem`); `validateFields(fields)` is the `@compileError`
wrapper.

Pre-built specs: `SpecV1987` (50+ fields, **all named** — e.g. DE4 is
`"Amount, transaction"`, DE70 is `"Network management information code"`),
`SpecV1993`, `SpecV2003`.

### Response Builders: setFieldPadded / setFieldInt

`setField` requires exactly `fixedLen` bytes. For hand-built responses,
the padded helpers format ISO conventions for you (buffer allocated from
the message's arena):

```zig
try iso8583.setFieldPadded(&msg, 4, "1000");   // DE4 fixed_12  → "000000001000" (numeric: right-aligned, '0')
try iso8583.setFieldPadded(&msg, 41, "T1");    // DE41 fixed_8  → "T1      "      (other: left-aligned, ' ')
try iso8583.setFieldInt(&msg, 11, 42);         // DE11 fixed_6  → "000042"
```

Errors: `FieldNotInSpec`, `NotFixedLength` (variable-length field),
`InvalidFieldLength` (value longer than fixed length), `NotNumericField`
(`setFieldInt` on a non-numeric field), `Overflow` (value does not fit).

### Transport Framing

Everything that surrounds an ISO 8583 message on the wire but is not part
of it lives in `iso8583.framing` — `decode()` still starts at the MTI:

```zig
// Inbound: 2-byte length prefix + transport header + message
const payload = try iso8583.stripTransportHeader(frame_body, 5); // 5B TPDU (or 12B B24 ext header)
try msg.decode(payload);

// Outbound
const lp = try iso8583.LengthPrefix.encode(header.len + encoded.len);
try writer.writeAll(&lp);
try iso8583.attachTransportHeader(writer, &header, encoded);
```

Errors: `FramingError{ BufferTooShort, LengthOverflow }`.

### Field Encodings

`FieldEncoding` — how field data is represented on the wire:

| Value | Bytes | Typical fields |
|-------|-------|----------------|
| `.ascii_numeric` | 1 per digit ('0'–'9') | DE2 PAN, DE4 amount, DE11 STAN |
| `.ascii_alpha` | 1 per char (A-Z a-z 0-9) | DE41 terminal, DE48 data |
| `.ascii_binary` | 2 per byte (hex chars) | hex-encoded sub-fields |
| `.bcd` | 2 digits per byte | BCD MTI, BCD bitmap |
| `.binary` | raw | DE52 PIN block, DE64 MAC, DE55 ICC |

### Length Types

`LengthType` — how a field's length is determined:

| Value | Wire format | Example |
|-------|-------------|---------|
| `.fixed_N` | exactly N bytes | `.fixed_12` amount: `000000001000` |
| `.llvar` | 2-digit ASCII prefix + data | DE2: `164111111111111111` |
| `.lllvar` | 3-digit ASCII prefix + data | DE48: `015ABCDEF0123456789` |
| `.llllvar` | 4-digit ASCII prefix + data | rare sub-fields |

Helpers: `fixedLen() ?usize`, `prefixDigits() ?u3`, `isVariable() bool`.

### MTI

The 4-digit Message Type Identifier: `V C F O`

- `V` — version: 0=1987, 1=1993, 2=2003
- `C` — class: 1=authorization, 2=financial, 4=reversal, 8=network mgmt
- `F` — function: 0=request, 1=response, 2=advice, 4=notification
- `O` — origin: 0=acquirer, 2=issuer, 4=other

| Signature | Description |
|-----------|-------------|
| `Mti.parse(buf: *const [4]u8) !Mti` | Parse from ASCII digits |
| `Mti.parseBcd(buf: *const [2]u8) !Mti` | Parse from BCD bytes |
| `mti.toAscii() [4]u8` | Encode as ASCII |
| `mti.toBcd() ![2]u8` | Encode as BCD |
| `mti.value() u16` | Decimal value (0100 → 100) |
| `mti.format(...)` | std.fmt support — `print("{}", .{mti})` |

Common MTIs: `0100`/`0110` auth request/response, `0200`/`0210` financial,
`0400`/`0420` reversal, `0800`/`0810` network management.

### Bitmap

128-bit presence bitmap (big-endian, MSB = field 1).

| Signature | Description |
|-----------|-------------|
| `Bitmap.init() Bitmap` | All-zero bitmap |
| `Bitmap.parse(buf) !{bitmap, consumed}` | Parse; auto-detects secondary |
| `bm.set(field_id) void` | Mark field present |
| `bm.unset(field_id) void` | Mark field absent |
| `bm.isPresent(field_id) bool` | Presence check |
| `bm.needsSecondary() bool` | Any field 65–128 set? |
| `bm.encode(out) !usize` | Write 8 or 16 bytes, sets bit 1 as needed |
| `bm.countPresent() u32` | SIMD popcount |
| `bm.presenceArray() [128]bool` | Full presence array |
| `bm.iterator() Iterator` | Ascending field-ID iteration (skips field 1) |

### SIMD Utilities

`iso8583.simd` — vectorized primitives with scalar fallbacks:

| Function | Description |
|----------|-------------|
| `validateAsciiDigits(slice) bool` | All bytes '0'–'9' (16/iter) |
| `validateAsciiDigitsWide(slice) bool` | Same, 32 bytes/iter |
| `validateAsciiAlnum(slice) bool` | All bytes alphanumeric (16/iter) |
| `bcdToAscii(bcd, out) void` | BCD → ASCII (16 bytes/iter) |
| `asciiToBcd(ascii, out) !void` | ASCII → BCD |
| `decodeBitmapPresence(bitmap) [128]bool` | Presence array |
| `countPresentFields(bitmap) u32` | Popcount |
| `memChr(haystack, needle) ?usize` | SIMD byte search |

### Validation

| Function | Description |
|----------|-------------|
| `validateFieldData(data, enc) !void` | Validate data against encoding rules |
| `validateAsciiHex(slice) bool` | SIMD hex validation (0-9 A-F a-f) |
| `RulesV1987` | Required-fields table for common 1987 MTIs |

### Error Sets

**DecodeError:** `InvalidMti`, `InvalidBitmap`, `InvalidFieldEncoding`,
`InvalidFieldLength`, `FieldTooLong`, `FieldNotInSpec` (only when
`unknown_fields == .reject` — the default), `InvalidBcdDigit`,
`BufferTooShort`, `UnexpectedEndOfMessage`, `OutOfMemory`

**EncodeError:** `FieldNotInSpec`, `FieldTooLong`, `FieldNotSet`,
`InvalidBcdDigit`, `BufferTooShort`, `OutOfMemory`; builders additionally
surface `NotFixedLength`, `NotNumericField`, `Overflow`

**ValidationError:** `InvalidDigits`, `InvalidAlnum`, `InvalidBinary`,
`InvalidLength`, `EmptyField`

**FramingError:** `BufferTooShort`, `LengthOverflow`

---

## ISO 8583 Primer

### Message Structure

```
┌─────────────────────────────────────────────────────────────┐
│ MTI │ Bitmap │ DE 2 │ DE 3 │ DE 4 │ ... │ DE 128          │
│ 4B  │ 8-16B  │ length-prefixed / fixed data per spec       │
└─────────────────────────────────────────────────────────────┘
```

1. **MTI** — 4 ASCII digits (or 2 BCD bytes) identifying the message purpose
2. **Bitmap** — 8 bytes (fields 2–64) or 16 bytes (fields 2–128); bit 1 of
   byte 0 indicates whether the secondary half follows
3. **Data Elements** — present fields in ascending order, each either
   fixed-length or prefixed with its length in ASCII digits

### Bitmap Layout

```
byte 0:  bit1=secondary-indicator  bit2=DE2  bit3=DE3 ... bit8=DE8
byte 1:  bit1=DE9  bit2=DE10 ... bit8=DE16
...
byte 7:  bit1=DE57 ... bit8=DE64
byte 8:  bit1=DE65 ...              (only if secondary present)
...
byte 15: ... bit8=DE128
```

Example: fields 2, 3, 4 present → byte 0 = `0111 0000` = `0x70`.

### Field Format Examples

| Field | Spec | Wire bytes | Meaning |
|-------|------|------------|---------|
| DE2 PAN | llvar ascii_numeric | `16` + `4111111111111111` | length 16, Visa test PAN |
| DE3 | fixed_6 ascii_numeric | `000000` | purchase (00 00 00) |
| DE4 | fixed_12 ascii_numeric | `000000001000` | $10.00 (implied 2 decimals) |
| DE7 | fixed_10 ascii_numeric | `0615123456` | MMDDhhmmss = Jun 15, 12:34:56 |
| DE11 | fixed_6 ascii_numeric | `000123` | STAN 123 |
| DE41 | fixed_8 ascii_alpha | `TERM0001` | terminal ID |
| DE48 | lllvar ascii_alpha | `015` + `ABCDEFGHIJKLM` | length 15 |
| DE52 | fixed_8 binary | `01 23 45 67 89 AB CD EF` | PIN block |
| DE64 | fixed_8 binary | 8 raw bytes | MAC |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        zig-iso8583                          │
├──────────────────┬──────────────────┬───────────────────────┤
│  comptime        │  runtime         │  simd                 │
│  spec engine     │  decode / encode │  validate / convert   │
│  (spec.zig)      │  (decoder.zig,   │  (simd.zig)           │
│                  │   encoder.zig)   │                       │
├──────────────────┴──────────────────┴───────────────────────┤
│              zero-copy slice views (zero_copy.zig)           │
├─────────────────────────────────────────────────────────────┤
│              ArenaAllocator (per-message, decoder.zig)       │
└─────────────────────────────────────────────────────────────┘
```

Module dependency flow:

```
iso8583.zig (root, re-exports)
├── spec.zig ──── field.zig ──── encoding.zig
├── decoder.zig ─┬─ bitmap.zig ── simd.zig
│                ├─ mti.zig ───── encoding.zig
│                └─ field.zig
├── encoder.zig ─ (same deps as decoder)
├── validate.zig ─ simd.zig
└── zero_copy.zig
```

## Design Pillars

### Zero-Copy

`decode()` never copies field bytes. `FieldStore` records `(ptr, len)` slices
into the source buffer plus an optional pre-parsed `u64` for numeric fields.
This eliminates allocation and memcpy costs on the hot path. The trade-off —
source-buffer lifetime — is documented and conventional.

### SIMD

Hot loops process 16 bytes per iteration via `@Vector(16, u8)`:

- digit/alnum validation: two range compares + `@select` + `@reduce(.And)`
- BCD→ASCII: nibble shifts/masks + `@shuffle` interleave
- memchr: vector equality + `@bitCast` to mask + `@ctz`

All functions fall back to scalar loops for tails (len % 16) so behavior is
identical at every length — covered by SIMD-vs-scalar consistency tests.

### Arena Allocation

Each `Message` embeds an `ArenaAllocator`. Decode performs **zero** heap
allocations (pure slicing); `setField` during encode writes into
caller-provided storage. One `deinit()` releases everything, and `reset()`
(`retain_capacity`) makes per-connection reuse allocation-free.

### Comptime

`Spec.define()` runs fully at comptime, producing a `[129]i16` direct-index
lookup table. Field access is O(1) array indexing — no hash maps, no binary
search. Because the spec is a comptime constant, the optimizer sees all field
descriptors and can specialize decode/encode paths per spec.

## Testing

407 tests across 8 suites, all passing:

```bash
zig build test
```

| Suite | Tests | Focus |
|-------|------:|-------|
| `src/iso8583.zig` | 65 | Module-level re-export & sub-module test discovery |
| `test_encoding.zig` | 38 | BCD codec, parsing, overflow, enums |
| `test_mti.zig` | 33 | All classes/functions, BCD+ASCII, round-trips |
| `test_bitmap.zig` | 45 | Every bit 0–127, boundaries, iterators |
| `test_simd.zig` | 43 | Length boundaries, SIMD↔scalar consistency |
| `test_spec.zig` | 60 | Custom specs, pre-built spec verification |
| `test_validate.zig` | 39 | Encoding rules, required-field rules |
| `test_integration.zig` | 84 | Full messages, round-trips, zero-copy proof, errors |

Benchmarks: `zig build bench`. Example: `zig build example`.

## Project Layout

```
zig-iso8583/
├── build.zig              # test / bench / example targets
├── build.zig.zon          # package manifest
├── DESIGN.md              # design document (source of truth)
├── README.md              # this file
├── src/
│   ├── iso8583.zig        # root: re-exports + module docs
│   ├── spec.zig           # comptime spec DSL + v1987/v1993/v2003
│   ├── encoding.zig       # BCD/ASCII codec, length prefixes
│   ├── mti.zig            # Message Type Identifier
│   ├── bitmap.zig         # 128-bit bitmap
│   ├── field.zig          # descriptors, FieldStore
│   ├── decoder.zig        # zero-copy decode pipeline
│   ├── encoder.zig        # encode pipeline
│   ├── validate.zig       # field validation + rules
│   ├── simd.zig           # SIMD primitives
│   ├── zero_copy.zig      # typed views, MessageBuffer
│   ├── bench.zig          # benchmarks
│   └── test_*.zig         # 7 comprehensive test suites
└── examples/
    └── basic.zig          # encode/decode with round-trip check
```

## License

MIT
