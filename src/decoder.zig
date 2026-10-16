//! # ISO 8583 Message Decoder (Parser)
//!
//! Zero-copy decode pipeline: parsed fields are `[]const u8` slices pointing
//! directly into the caller's source buffer — no field data is copied.
//!
//! ## Decode Pipeline
//!
//! ```text
//! ┌──────┬──────────┬─────────────────────────────────────┐
//! │ MTI  │  Bitmap  │  DE2 │ DE3 │ DE4 │ ...  │ DE128     │
//! └──────┴──────────┴─────────────────────────────────────┘
//!    │         │                  │
//!    ▼         ▼                  ▼
//!  Mti      Bitmap    FieldStore (slices into buf)
//! ```
//!
//! 1. **MTI** — parsed per `spec.mti_encoding` (ASCII or BCD)
//! 2. **Bitmap** — parsed per `spec.bitmap_encoding`; auto-detects secondary
//! 3. **Fields** — iterated in bitmap order; each is length-parsed per its
//!    `LengthType`, validated against the spec, and stored as a slice
//!
//! ## Usage
//!
//! ```zig
//! var msg = try iso8583.Message.init(allocator, &iso8583.SpecV1987);
//! defer msg.deinit();               // frees arena — one call
//! try msg.decode(wire_bytes);
//!
//! const pan = msg.getField(2).?;    // zero-copy []const u8
//! const amount = msg.getFieldInt(4); // pre-parsed ?u64
//! ```
//!
//! ## Memory Management
//!
//! Each `Message` owns an `ArenaAllocator`. All allocations during decode
//! (currently none for field data — zero copy) come from this arena and are
//! released in one `deinit()` call. Use `reset()` to reuse the message for
//! another decode without returning memory to the backing allocator —
//! ideal for server request loops.
//!
//! ## Lifetime Contract
//!
//! Decoded field slices reference the buffer passed to `decode()`. The
//! caller must keep that buffer alive and unmodified for as long as the
//! `Message` (or any field view from it) is in use.

const std = @import("std");
const spec_mod = @import("spec.zig");
const bitmap_mod = @import("bitmap.zig");
const mti_mod = @import("mti.zig");
const field_mod = @import("field.zig");
const encoding = @import("encoding.zig");
const simd = @import("simd.zig");

pub const Spec = spec_mod.Spec;
pub const Bitmap = bitmap_mod.Bitmap;
pub const Mti = mti_mod.Mti;
pub const FieldStore = field_mod.FieldStore;
pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

// ─── Error Set ─────────────────────────────────────────────────────────────

/// Errors that can occur during message decoding.
pub const DecodeError = error{
    /// MTI contains a non-digit byte.
    InvalidMti,
    /// Bitmap region is malformed.
    InvalidBitmap,
    /// Field data fails encoding rules (e.g., non-digit in numeric field).
    InvalidFieldEncoding,
    /// Field length contradicts spec (fixed-length mismatch).
    InvalidFieldLength,
    /// Variable-length field exceeds its spec max_len.
    FieldTooLong,
    /// Present in bitmap but not defined in the spec. Only returned when
    /// `Spec.unknown_fields == .reject` (the default); `.skip` ignores the
    /// field instead. See `Message.last_unknown_field` for the offending ID.
    FieldNotInSpec,
    /// BCD data contains an invalid nibble (> 9).
    InvalidBcdDigit,
    /// Buffer ends before the message is complete.
    BufferTooShort,
    /// Field data extends past end of buffer.
    UnexpectedEndOfMessage,
    /// Backing allocator failed.
    OutOfMemory,
};

// ─── Decoded Message ───────────────────────────────────────────────────────

/// A decoded ISO 8583 message.
///
/// Fields are zero-copy views into the source buffer passed to `decode()`.
/// Owns an arena for internal allocations; `deinit()` releases everything.
///
/// ```zig
/// var msg = try Message.init(allocator, &iso8583.SpecV1987);
/// defer msg.deinit();
/// try msg.decode(wire_bytes);
///
/// msg.mti.class == .authorization;
/// msg.getField(2) != null;          // PAN present
/// msg.getFieldInt(4) == 1000;       // amount pre-parsed
/// ```
pub const Message = struct {
    /// Arena allocator owning this message's heap memory.
    arena: std.heap.ArenaAllocator,
    /// Parsed Message Type Identifier.
    mti: Mti,
    /// Parsed presence bitmap (8 or 16 bytes).
    bitmap: Bitmap,
    /// Zero-copy field storage.
    field_store: FieldStore,
    /// The comptime spec this message conforms to.
    spec: *const Spec,
    /// Set when `decode()` encountered a field present in the bitmap but
    /// missing from the spec (before honoring `spec.unknown_fields`).
    /// Enables precise diagnostics: `DE{last_unknown_field} not in spec`.
    last_unknown_field: ?u8 = null,

    const Self = @This();

    /// Initialize a message with the given backing allocator and spec.
    /// Initialize a message with the given backing allocator and spec.
    ///
    /// The spec must be a comptime constant (e.g., `&iso8583.SpecV1987`).
    /// Returns error.OutOfMemory if the arena cannot be created.
    pub fn init(backing: std.mem.Allocator, s: *const Spec) !Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .mti = undefined,
            .bitmap = Bitmap.init(),
            .field_store = FieldStore.init(),
            .spec = s,
        };
    }

    /// Deallocate all memory used by this message.
    /// Deallocate all memory used by this message. Required after use.
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Reset the message for reuse (keeps arena memory, clears fields).
    /// Reset the message for reuse (keeps arena memory, clears fields).
    ///
    /// Cheaper than deinit+init for server loops processing many messages:
    /// the arena's capacity is retained and reused.
    pub fn reset(self: *Self) void {
        self.field_store = FieldStore.init();
        self.bitmap = Bitmap.init();
        self.last_unknown_field = null;
        _ = self.arena.reset(.retain_capacity);
    }

    /// Decode a raw wire-format byte slice into this message.
    ///
    /// Parses MTI → bitmap → fields in order. All field data remains as
    /// slices into `buf` — nothing is copied (zero-copy). The caller must
    /// keep `buf` alive and unmodified while this message is in use.
    ///
    /// ## Errors
    /// See `DecodeError`. The message may be partially populated if an
    /// error occurs mid-decode; call `reset()` before reusing it.
    pub fn decode(self: *Self, buf: []const u8) !void {
        var offset: usize = 0;

        // 1. Parse MTI
        offset = try self.decodeMti(buf, offset);

        // 2. Parse Bitmap
        offset = try self.decodeBitmap(buf, offset);

        // 3. Parse fields according to bitmap and spec
        offset = try self.decodeFields(buf, offset);
    }

    /// Decode the MTI from the buffer.
    fn decodeMti(self: *Self, buf: []const u8, offset: usize) !usize {
        switch (self.spec.mti_encoding) {
            .ascii => {
                if (buf.len < offset + 4) return error.BufferTooShort;
                self.mti = try Mti.parse(buf[offset..][0..4]);
                return offset + 4;
            },
            .bcd => {
                if (buf.len < offset + 2) return error.BufferTooShort;
                self.mti = try Mti.parseBcd(buf[offset..][0..2]);
                return offset + 2;
            },
        }
    }

    /// Decode the bitmap from the buffer.
    fn decodeBitmap(self: *Self, buf: []const u8, offset: usize) !usize {
        switch (self.spec.bitmap_encoding) {
            .binary => {
                const result = try Bitmap.parse(buf[offset..]);
                self.bitmap = result.bitmap;
                return offset + result.consumed;
            },
            .bcd => {
                // BCD bitmap: primary = 16 bytes (8 BCD bytes → 16 hex digits → 64 bits)
                // Secondary = 32 bytes
                if (buf.len < offset + 16) return error.BufferTooShort;

                // Decode primary bitmap from BCD
                var primary_raw: [8]u8 = undefined;
                try simd.asciiToBcd(buf[offset..][0..16], &primary_raw);

                var need_secondary = false;
                if ((primary_raw[0] & 0x80) != 0) {
                    need_secondary = true;
                    if (buf.len < offset + 32) return error.BufferTooShort;
                }

                var bm = Bitmap.init();
                @memcpy(bm.raw[0..8], &primary_raw);

                if (need_secondary) {
                    var secondary_raw: [8]u8 = undefined;
                    try simd.asciiToBcd(buf[offset + 16 ..][0..16], &secondary_raw);
                    @memcpy(bm.raw[8..16], &secondary_raw);
                    self.bitmap = bm;
                    return offset + 32;
                }

                self.bitmap = bm;
                return offset + 16;
            },
        }
    }

    /// Decode all fields present in the bitmap.
    fn decodeFields(self: *Self, buf: []const u8, start_offset: usize) !usize {
        var offset = start_offset;
        var bitmap_iter = self.bitmap.iterator();

        while (bitmap_iter.next()) |field_id| {
            const desc = self.spec.lookupRuntime(field_id) orelse {
                self.last_unknown_field = @intCast(field_id);
                switch (self.spec.unknown_fields) {
                    // Legacy lenient behavior: pretend the field isn't there.
                    .skip => continue,
                    // Strict (default): a bitmap field outside the spec means
                    // a misrouted terminal or dialect drift — never decode
                    // "successfully" with fields silently missing.
                    .reject => return error.FieldNotInSpec,
                }
            };
            const result = try self.decodeField(buf, offset, field_id, desc);
            offset = result;
        }

        return offset;
    }

    /// Decode a single field from the buffer. Returns the new offset.
    fn decodeField(
        self: *Self,
        buf: []const u8,
        offset: usize,
        field_id: usize,
        desc: spec_mod.FieldDescriptor,
    ) !usize {
        if (offset >= buf.len) return error.UnexpectedEndOfMessage;

        var field_len: usize = 0;
        var data_offset: usize = offset;

        switch (desc.length_type) {
            .llvar, .lllvar, .llllvar => {
                const prefix_digits = desc.length_type.prefixDigits().?;
                if (buf.len < offset + prefix_digits) return error.BufferTooShort;

                // Parse length prefix
                const parsed = try encoding.parseLengthPrefix(buf[offset..], prefix_digits);
                field_len = parsed.len;
                data_offset = offset + prefix_digits;

                // Validate length
                if (desc.max_len > 0 and field_len > desc.max_len)
                    return error.FieldTooLong;
            },
            else => {
                // Fixed-length field
                field_len = desc.length_type.fixedLen().?;
            },
        }

        // Read field data (zero-copy: just point into buf)
        if (buf.len < data_offset + field_len) return error.BufferTooShort;
        const field_data = buf[data_offset .. data_offset + field_len];

        // For BCD fields, the wire length is half the logical length
        const wire_data = switch (desc.encoding) {
            .bcd => blk: {
                // BCD: wire bytes = ceil(logical_digits / 2)
                // For fixed fields, the length_type gives the number of digits
                // The wire bytes is ceil(digits / 2)
                // But for variable, field_len is already in bytes
                break :blk field_data;
            },
            else => field_data,
        };

        // Pre-parse numeric values
        var int_val: ?u64 = null;
        switch (desc.encoding) {
            .ascii_numeric => {
                // Only parse if it fits in u64 (max 19 digits)
                if (wire_data.len > 0 and wire_data.len <= 19) {
                    // Skip leading zeros for parsing
                    int_val = encoding.parseAsciiUint(u64, wire_data) catch null;
                }
            },
            else => {},
        }

        // Store the field (zero-copy)
        self.field_store.set(field_id, wire_data, int_val);

        return data_offset + field_len;
    }

    // ─── Field Access ──────────────────────────────────────────────────────

    /// Get a field's raw data (zero-copy view). Returns null if not present.
    ///
    /// ```zig
    /// if (msg.getField(2)) |pan| {
    ///     std.log.info("PAN: {s}", .{pan});  // "4111111111111111"
    /// }
    /// ```
    pub fn getField(self: Self, field_id: usize) ?[]const u8 {
        return self.field_store.get(field_id);
    }

    /// Get a field's pre-parsed integer value.
    ///
    /// Populated during decode for `ascii_numeric` fields up to 19 digits.
    /// Returns null for absent fields, non-numeric fields, or values that
    /// overflow u64.
    pub fn getFieldInt(self: Self, field_id: usize) ?u64 {
        return self.field_store.getInt(field_id);
    }

    /// Check if a field is present in the decoded message.
    pub fn isPresent(self: Self, field_id: usize) bool {
        return self.field_store.isPresent(field_id);
    }

    /// Count the number of present fields.
    pub fn fieldCount(self: Self) usize {
        return self.field_store.count();
    }

    /// Iterate present field IDs in ascending order.
    ///
    /// ```zig
    /// var iter = msg.fieldIterator();
    /// while (iter.next()) |field_id| {
    ///     std.log.info("DE{}: {s}", .{ field_id, msg.getField(field_id).? });
    /// }
    /// ```
    pub fn fieldIterator(self: *const Self) FieldStore.Iterator {
        return self.field_store.iterator();
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

test "decode simple message" {
    const test_spec = comptime spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
            field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
            field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
            field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
            field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
            field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
            field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        },
    });

    // Build a test message:
    // MTI: "0100" (authorization request)
    // Bitmap: fields 2, 3, 4, 7, 11, 41, 49
    // Field 2 (LLVAR): "164111111111111111" → PAN = 4111111111111111
    // Field 3: "000000"
    // Field 4: "000000001000"
    // Field 7: "0606123456"
    // Field 11: "000001"
    // Field 41: "TERM001 "
    // Field 49: "840"

    var msg_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer msg_buf.deinit();
    const writer = msg_buf.writer();

    // MTI
    try writer.writeAll("0100");

    // Bitmap: fields 2, 3, 4, 7, 11, 41, 49
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(7);
    bm.set(11);
    bm.set(41);
    bm.set(49);
    try writer.writeAll(bm.raw[0..8]);

    // Field 2: LLVAR — length prefix "16" + data "4111111111111111"
    try writer.writeAll("164111111111111111");

    // Field 3: fixed 6
    try writer.writeAll("000000");

    // Field 4: fixed 12
    try writer.writeAll("000000001000");

    // Field 7: fixed 10
    try writer.writeAll("0606123456");

    // Field 11: fixed 6
    try writer.writeAll("000001");

    // Field 41: fixed 8
    try writer.writeAll("TERM001 ");

    // Field 49: fixed 3
    try writer.writeAll("840");

    // Now decode
    var msg = try Message.init(std.testing.allocator, &test_spec);
    defer msg.deinit();

    try msg.decode(msg_buf.items);

    // Verify MTI
    try std.testing.expectEqual(mti_mod.MsgClass.authorization, msg.mti.class);
    try std.testing.expectEqual(mti_mod.MsgFunction.request, msg.mti.function);

    // Verify fields
    try std.testing.expect(msg.isPresent(2));
    try std.testing.expect(msg.isPresent(3));
    try std.testing.expect(msg.isPresent(4));
    try std.testing.expect(msg.isPresent(7));
    try std.testing.expect(msg.isPresent(11));
    try std.testing.expect(msg.isPresent(41));
    try std.testing.expect(msg.isPresent(49));

    // Verify field values (zero-copy)
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
    try std.testing.expectEqualSlices(u8, "000000", msg.getField(3).?);
    try std.testing.expectEqualSlices(u8, "000000001000", msg.getField(4).?);
    try std.testing.expectEqualSlices(u8, "TERM001 ", msg.getField(41).?);
    try std.testing.expectEqualSlices(u8, "840", msg.getField(49).?);

    // Verify pre-parsed integer
    try std.testing.expectEqual(@as(?u64, 4111111111111111), msg.getFieldInt(2));
    try std.testing.expectEqual(@as(?u64, 1000), msg.getFieldInt(4));
}

test "decode message with secondary bitmap" {
    const test_spec = comptime spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
            field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
            field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
            field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
            field_mod.field(52, .fixed_8, .binary, .{}),
        },
    });

    var msg_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer msg_buf.deinit();
    const writer = msg_buf.writer();

    // MTI
    try writer.writeAll("0200");

    // Bitmap with secondary: fields 2, 3, 4, 48, 52
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(48);
    bm.set(52);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try writer.writeAll(bm_bytes[0..bm_len]);

    // Field 2: LLVAR
    try writer.writeAll("164111111111111111");
    // Field 3
    try writer.writeAll("000000");
    // Field 4
    try writer.writeAll("000000001000");
    // Field 48: LLLVAR
    try writer.writeAll("016ABCDEF0123456789");
    // Field 52: binary (8 bytes)
    try writer.writeAll("\x01\x02\x03\x04\x05\x06\x07\x08");

    var msg = try Message.init(std.testing.allocator, &test_spec);
    defer msg.deinit();

    try msg.decode(msg_buf.items);

    try std.testing.expectEqual(mti_mod.MsgClass.financial, msg.mti.class);
    try std.testing.expect(msg.isPresent(2));
    try std.testing.expect(msg.isPresent(3));
    try std.testing.expect(msg.isPresent(4));
    try std.testing.expect(msg.isPresent(48));
    try std.testing.expect(msg.isPresent(52));

    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
    try std.testing.expectEqualSlices(u8, "ABCDEF0123456789", msg.getField(48).?);
}

test "decode with BCD MTI" {
    const test_spec = comptime spec_mod.Spec.define(.{
        .version = .v1987,
        .mti_encoding = .bcd,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        },
    });

    var msg_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer msg_buf.deinit();
    const writer = msg_buf.writer();

    // BCD MTI: 0x01 0x00 = "0100"
    try writer.writeAll(&[_]u8{ 0x01, 0x00 });

    // Bitmap: field 2
    var bm = Bitmap.init();
    bm.set(2);
    try writer.writeAll(bm.raw[0..8]);

    // Field 2
    try writer.writeAll("164111111111111111");

    var msg = try Message.init(std.testing.allocator, &test_spec);
    defer msg.deinit();

    try msg.decode(msg_buf.items);

    try std.testing.expectEqual(mti_mod.MsgClass.authorization, msg.mti.class);
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
}

test "Message.reset" {
    const test_spec = comptime spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        },
    });

    var msg = try Message.init(std.testing.allocator, &test_spec);
    defer msg.deinit();

    // Simple message
    const buf_data = "0100" ++ [_]u8{0x40, 0, 0, 0, 0, 0, 0, 0} ++ "164111111111111111";
    try msg.decode(buf_data);
    try std.testing.expect(msg.isPresent(2));

    msg.reset();
    try std.testing.expect(!msg.isPresent(2));
}
