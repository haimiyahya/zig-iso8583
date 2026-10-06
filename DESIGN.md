# zig-iso8583 — Design Document

> A high-performance ISO 8583 parser/serializer in Zig  
> leveraging SIMD, zero-copy, ArenaAllocator, and comptime metaprogramming.

---

## 1. ISO 8583 Overview

ISO 8583 is the international standard for financial transaction card-originated
interchange messaging. Key structural elements:

| Component       | Description                                            |
|-----------------|--------------------------------------------------------|
| **MTI**         | 4-digit Message Type Identifier (e.g., `0100` authorization request) |
| **Bitmap**      | 8 or 16 bytes (primary + optional secondary) indicating which fields are present |
| **Data Elements** | Up to 128 fields, each with type/length/encoding rules  |
| **Sub-fields**  | Some fields (e.g., DE22, DE48, DE62) contain nested sub-elements |
| **LLVAR/LLLVAR** | Variable-length fields prefixed by 2 or 3 digit length indicators |

### Common Encodings per Field

| Encoding        | Example fields  | Description                                  |
|-----------------|-----------------|----------------------------------------------|
| **BCD**         | MTI, bitmap, fixed numeric fields | Packed 2 digits per byte   |
| **ASCII numeric** | DE4, DE22     | Each digit = 1 ASCII byte (`0x30`–`0x39`)    |
| **ASCII alpha**   | DE48 subfields | Text characters                              |
| **Binary**        | DE52 (PIN block) | Raw bytes                                 |
| **LLVAR ASCII**  | DE2 (PAN)      | 2-digit length prefix + ASCII data           |
| **LLLVAR ASCII** | DE48, DE62     | 3-digit length prefix + ASCII data           |
| **LLVAR BCD**    | some PIN blocks | 2-digit length prefix + BCD data            |

### Key ISO 8583 Versions

- **1987** — Classic, still widely used
- **1993** — Minor updates
- **2003** — Major revision with new data elements

This library will support all three, selected at **comptime**.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      zig-iso8583                         │
├──────────────┬──────────────┬───────────────────────────┤
│   comptime   │   runtime    │         simd              │
│  spec engine │ parse/emit   │  bitmap/validate/search   │
├──────────────┴──────────────┴───────────────────────────┤
│                    zero-copy slice views                 │
├─────────────────────────────────────────────────────────┤
│                 ArenaAllocator (per-message)             │
└─────────────────────────────────────────────────────────┘
```

### 2.1 Module Structure

```
src/
├── iso8583.zig          # Root — public API
├── spec.zig             # Comptime message specification DSL
├── field.zig            # Field type system (comptime-generated)
├── bitmap.zig           # Bitmap encode/decode with SIMD
├── mti.zig              # MTI parsing & validation
├── decoder.zig          # Main decode pipeline
├── encoder.zig          # Main encode pipeline
├── simd.zig             # SIMD primitives (search, compare, convert)
├── encoding.zig         # BCD/ASCII/Binary codec functions
├── validate.zig         # Field validation (comptime rules + SIMD)
├── zero_copy.zig        # Slice-based view types
└── test/
    ├── test_decode.zig
    ├── test_encode.zig
    ├── test_roundtrip.zig
    ├── test_simd.zig
    └── test_spec.zig
```

---

## 3. Core Design Decisions

### 3.1 Zero-Copy Design

**Principle:** Decoded fields are *views* (slices) into the original message
buffer — no copying of field data during decode.

```zig
/// A decoded field is a typed view into the source buffer.
pub const FieldView = struct {
    field_id: comptime_int,
    encoding: FieldEncoding,
    /// Byte slice pointing into original message buffer (zero-copy)
    raw: []const u8,
    /// For numeric fields: decoded value stored inline (fits in u64 for most fields)
    int_val: ?u64 = null,
};
```

**Trade-off:** Caller must ensure the source buffer outlives the decoded
message. This is the standard zero-copy contract and is well-understood.

**When copies happen (only during encode):**
- Variable-length field length prefixes are computed and prepended
- BCD encoding may require nibble manipulation that produces new bytes
- The encode buffer is pre-allocated from the arena

### 3.2 ArenaAllocator — Per-Message Memory Strategy

```zig
pub const Message = struct {
    arena: std.heap.ArenaAllocator,
    fields: FieldStore,
    mti: Mti,
    spec: *const Spec,

    pub fn init(backing: std.mem.Allocator, spec: *const Spec) !Message { ... }
    pub fn deinit(self: *Message) void {
        self.arena.deinit();
    }
};
```

**Why Arena?**
- A single ISO 8583 message has potentially 128 fields
- Arena eliminates per-field allocation overhead
- Bulk deallocation on `deinit()` — no per-field free
- Arena can be reset (`.reset()`) for message reuse in server loops
- Typical message size < 4KB — arena overhead is minimal

### 3.3 Comptime Specification Engine

The spec DSL runs entirely at comptime, producing optimized runtime code:

```zig
// Define a specification at comptime
const Visa87Spec = comptime Spec.define(.{
    .version = .v1987,
    .fields = &.{
        Spec.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),  // PAN
        Spec.field(3, .fixed_6, .ascii_numeric, .{}),                // Processing code
        Spec.field(4, .fixed_12, .ascii_numeric, .{}),               // Amount
        Spec.field(22, .fixed_3, .ascii_numeric, .{}),               // POS entry mode
        Spec.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }), // Additional data
        Spec.field(52, .fixed_8, .binary, .{}),                      // PIN block
        // ... remaining fields
    },
});

// Usage — the spec is a compile-time constant, all dispatch is monomorphized
var msg = try Message.init(allocator, &Visa87Spec);
try msg.decode(raw_bytes);
const pan = msg.getField(2);  // Field ID known at comptime → direct access
```

**Comptime benefits:**
- Field layout is known → generated as a packed struct or indexed array
- No hash map lookup for fields; `getField(N)` compiles to direct index access
- Bitmap presence checks can be inlined
- Variable-length field max lengths enable compile-time buffer sizing
- Version-specific differences are branch-eliminated at compile time

### 3.4 SIMD Acceleration

#### 3.4.1 Bitmap Scanning

Finding present fields from a 128-bit bitmap is a critical hot path.

```zig
/// Scan a 128-bit bitmap and return a vector of present field IDs.
/// Uses SIMD to test 32 bits at once (4 × u32 vectors).
pub fn scanBitmap(bitmap: *const [16]u8) BitmapIter {
    // Load 128-bit bitmap as 4 × u32 SIMD vector
    const v = @bitCast(@Vector(4, u32), bitmap.*);
    // SIMD compare against zero to find set lanes
    const mask = v != @splat(4, @as(u32, 0));
    // Extract bit positions using SIMD population count + tzcnt
    ...
}
```

#### 3.4.2 ASCII Digit Validation

Validate that a byte slice contains only ASCII digits (`0x30`–`0x39`):

```zig
/// Validate ASCII digits using SIMD. Processes 32 bytes per iteration.
pub fn validateAsciiDigits(slice: []const u8) bool {
    const Vec32 = @Vector(32, u8);
    const lo = @splat(32, @as(u8, 0x30));
    const hi = @splat(32, @as(u8, 0x39));
    var i: usize = 0;
    while (i + 32 <= slice.len) : (i += 32) {
        const v: Vec32 = slice[i..][0..32].*;
        const ge_lo = v >= lo;
        const le_hi = v <= hi;
        const valid = ge_lo and le_hi;  // SIMD comparison
        if (@reduce(.And, valid) == false) return false;
    }
    // Scalar tail
    for (slice[i..]) |b| {
        if (b < 0x30 or b > 0x39) return false;
    }
    return true;
}
```

#### 3.4.3 BCD ↔ ASCII Conversion

Convert BCD nibbles to ASCII digits (and vice versa) 16 bytes at a time:

```zig
/// BCD → ASCII: each BCD byte '0xAB' → 'A','B' as ASCII digits
/// Processes 16 BCD bytes → 32 ASCII bytes per SIMD iteration.
pub fn bcdToAscii(bcd: []const u8, out: []u8) void {
    const V16 = @Vector(16, u8);
    const mask_lo: V16 = @splat(16, @as(u8, 0x0F));
    const ascii_offset: V16 = @splat(16, @as(u8, 0x30));
    var i: usize = 0;
    while (i + 16 <= bcd.len) : (i += 16) {
        const v: V16 = bcd[i..][0..16].*;
        const hi_nibbles = (v >> @splat(16, @as(u8, 4))) + ascii_offset;
        const lo_nibbles = (v & mask_lo) + ascii_offset;
        // Interleave hi/lo into output using shuffle
        out[i * 2 ..][0..32].* = @shuffle(u8, lo_nibbles, hi_nibbles, shuffle_idx);
    }
    // Scalar tail...
}
```

#### 3.4.4 Length-Prefix Search (LLVAR/LLLVAR parsing)

SIMD-accelerated search for length-prefix boundaries when parsing
variable-length fields in a bulk scan pattern.

---

## 4. Type System

### 4.1 Field Encoding Enum

```zig
pub const FieldEncoding = enum {
    ascii_numeric,   // ASCII digits 0-9
    ascii_alpha,     // ASCII alphanumeric
    ascii_binary,    // ASCII hex representation of binary
    bcd,             // Binary Coded Decimal
    binary,          // Raw bytes
};
```

### 4.2 Field Length Type Enum

```zig
pub const LengthType = enum {
    fixed_1,   fixed_2,   fixed_3,   fixed_4,
    fixed_5,   fixed_6,   fixed_7,   fixed_8,
    fixed_10,  fixed_12,  fixed_16,  fixed_20,
    fixed_24,  fixed_28,  fixed_32,  fixed_35,
    fixed_36,  fixed_40,  fixed_41,  fixed_42,
    fixed_48,  fixed_52,  fixed_56,  fixed_64,
    fixed_76,  fixed_80,  fixed_96,  fixed_100,
    fixed_128,
    llvar,     // 2-digit length prefix
    lllvar,    // 3-digit length prefix
    llllvar,   // 4-digit length prefix (rare, some DE48 subfields)
};
```

### 4.3 Comptime Field Descriptor

```zig
pub const FieldDescriptor = struct {
    id: comptime_int,
    length_type: LengthType,
    encoding: FieldEncoding,
    max_len: usize = 0,        // For variable-length fields
    has_subfields: bool = false,
    sub_spec: ?*const Spec = null,
};
```

---

## 5. Public API

### 5.1 Decode (Parse)

```zig
const iso8583 = @import("iso8583");

// 1. Define or select a spec (comptime)
const MySpec = iso8583.Spec.define(.{
    .version = .v1987,
    .fields = &.{ /* ... */ },
});

// 2. Decode a message
var msg = try iso8583.Message.init(allocator, &MySpec);
try msg.decode(raw_bytes);

// 3. Access fields (zero-copy)
const mti = msg.mti();                          // → Mti struct
const pan = msg.field(2);                        // → []const u8 view
const amount = msg.fieldAs(u64, 4);             // → parsed u64
const pin_block = msg.field(52);                 // → []const u8 (binary)
const is_set = msg.isPresent(48);                // → bool

// 4. Iterate present fields
var iter = msg.fieldIterator();
while (iter.next()) |f| {
    std.log.info("DE{}: {s}", .{ f.id, f.raw });
}
```

### 5.2 Encode (Serialize)

```zig
// 1. Create a message
var msg = try iso8583.Message.init(allocator, &MySpec);
msg.setMti(.{ .class = .authorization, .function = .request, .origin = .acquirer });

// 2. Set fields
try msg.setField(2, "4111111111111111");         // PAN
try msg.setField(3, "000000");                    // Processing code
try msg.setField(4, "000000001000");              // Amount = 10.00
try msg.setField(22, "011");                      // POS entry mode
try msg.setField(52, &pin_block_bytes);           // PIN block (binary)

// 3. Encode to bytes
var buf = std.ArrayList(u8).init(allocator);
try msg.encode(buf.writer());
const wire_bytes = buf.items;
```

### 5.3 Round-trip

```zig
// Decode → Encode must produce byte-identical output
var msg = try iso8583.Message.init(allocator, &MySpec);
try msg.decode(wire_bytes);

var buf = std.ArrayList(u8).init(allocator);
try msg.encode(buf.writer());

try std.testing.expectEqualSlices(u8, wire_bytes, buf.items);
```

---

## 6. SIMD Strategy Details

| Operation                    | SIMD Width | Throughput Gain vs Scalar |
|------------------------------|------------|---------------------------|
| Bitmap scan (128-bit)        | 4 × u32    | ~4× (parallel bit tests)  |
| ASCII digit validation       | 32 × u8    | ~16–32× (vector compare)  |
| BCD → ASCII conversion       | 16 × u8    | ~8× (parallel nibble extract + shuffle) |
| ASCII → BCD conversion       | 16 × u8    | ~8× (parallel digit pair → nibble) |
| Length-prefix digit parse    | 16 × u8    | ~4× (vector digit validation + reduce) |
| Memchr (field delimiter)     | 32 × u8    | ~16–32× (vector eq + mask) |

**Fallback:** All SIMD functions have scalar fallback loops for:
- Sub-vector-length tails
- Platforms where `@Vector` is not natively supported
- Comptime-known small sizes where SIMD overhead isn't worth it

---

## 7. Memory Layout

```
Message (stack-allocated struct)
├── arena: ArenaAllocator        ← owns all heap memory for this message
├── mti: Mti                     ← 4 bytes, decoded inline
├── bitmap: [16]u8               ← 128-bit bitmap, decoded inline
├── field_store: FieldStore      ← comptime-generated, see below
└── spec: *const Spec            ← pointer to comptime spec (0 cost)

FieldStore (comptime-generated based on spec)
├── present: bitset              ← 128-bit presence bitmask
├── entries: [N]FieldEntry       ← N = number of fields in spec
│   └── FieldEntry
│       ├── raw: []const u8      ← zero-copy slice into source buffer
│       └── int_val: ?u64        ← pre-parsed numeric (if applicable)
└── (no HashMap — direct index via field ID)
```

---

## 8. Error Handling

```zig
pub const Error = error{
    InvalidMti,
    InvalidBitmap,
    InvalidFieldEncoding,
    InvalidFieldLength,
    FieldTooLong,
    FieldNotPresent,
    FieldNotInSpec,
    InvalidBcdDigit,
    BufferTooShort,
    UnexpectedEndOfMessage,
    DuplicateField,
    InvalidSubfield,
};
```

Errors are returned as Zig error unions — no exceptions, no allocations in
error paths.

---

## 9. Comptime Specialization Examples

### 9.1 Version-Specific Code

```zig
pub fn decodeField(comptime version: Version, ...) !FieldView {
    switch (version) {
        .v1987 => { /* 1987-specific decode */ },
        .v1993 => { /* 1993-specific decode */ },
        .v2003 => { /* 2003-specific decode */ },
    }
    // After comptime elimination, only one branch remains
}
```

### 9.2 Field-Type-Specific Code

```zig
pub fn decodeValue(
    comptime encoding: FieldEncoding,
    comptime length_type: LengthType,
    buf: []const u8,
) !FieldView {
    // Each combination generates a specialized function
    // No runtime dispatch overhead
}
```

### 9.3 Spec-Validated Encode

```zig
pub fn setField(self: *Message, comptime id: comptime_int, value: []const u8) !void {
    comptime {
        const desc = self.spec.lookup(id);
        // Compile-time check that field exists in spec
        std.debug.assert(desc != null);
    }
    // Runtime validation against comptime-known constraints
    if (value.len > self.spec.lookup(id).?.max_len) return error.FieldTooLong;
    ...
}
```

---

## 10. Testing Strategy

| Test Category         | Description                                         |
|-----------------------|-----------------------------------------------------|
| Unit — SIMD           | Validate SIMD helpers vs scalar reference            |
| Unit — BCD codec      | Round-trip BCD ↔ ASCII for all nibble combinations   |
| Unit — Bitmap         | Set/clear/scan all 128 bits                         |
| Integration — Decode  | Parse real ISO 8583 message captures                 |
| Integration — Encode  | Build messages and compare to known-good wire format |
| Round-trip            | Decode → Encode must be byte-identical              |
| Fuzz                  | Random valid messages, random corruption             |
| Benchmark             | Throughput: messages/sec for decode and encode       |
| Spec — v1987          | Full spec with all common fields                    |
| Spec — v1993          | v1993-specific field differences                    |
| Spec — v2003          | v2003-specific fields and encodings                 |

---

## 11. Performance Targets

| Metric                     | Target               |
|----------------------------|----------------------|
| Decode throughput          | > 1M msg/sec         |
| Encode throughput          | > 800K msg/sec       |
| Zero-copy field access     | O(1) — direct index  |
| Arena allocs per message   | ≤ 2 (field store + encode buf) |
| SIMD path activation       | Auto-detected at comptime via `@hasDecl` / CPU features |

---

## 12. Implementation Order

| Phase | Milestone                              | Files                              |
|-------|----------------------------------------|------------------------------------|
| 1     | Core types + spec DSL                  | `spec.zig`, `field.zig`, `encoding.zig`, `mti.zig` |
| 2     | Bitmap encode/decode + SIMD            | `bitmap.zig`, `simd.zig`          |
| 3     | Decoder (zero-copy)                    | `decoder.zig`, `zero_copy.zig`    |
| 4     | Encoder                                | `encoder.zig`                     |
| 5     | Validation + SIMD validation           | `validate.zig`                    |
| 6     | Pre-built specs (v1987, v1993, v2003)  | `spec.zig` additions              |
| 7     | Integration tests + benchmarks         | `test/`                           |
| 8     | Documentation + examples               | `README.md`, `examples/`          |

---

## 13. Future Considerations

- **Sub-field parsing** — DE22, DE48, DE62 nested TLV/LTV parsing
- **TCP framing** — 2-byte and 4-byte length prefix framing helpers
- **Async I/O integration** — Compatible with Zig's async I/O for server use
- **Schema validation** — Comptime message schema validation (required fields per MTI)
- **JSON gateway** — Optional ISO 8583 ↔ JSON conversion for debugging/API use

---

*This design document is the source of truth for implementation. All code must
conform to the contracts described herein.*
