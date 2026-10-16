//! # ISO 8583 Message Encoder (Serializer)
//!
//! Builds wire-format bytes from a `Message` and writes them to any
//! `std.io.Writer`.
//!
//! ## Encode Pipeline
//!
//! ```text
//! Message ──► encode() ──► writer
//!              │
//!              ├─ 1. encodeMti()     — ASCII "0100" or BCD 0x01 0x00
//!              ├─ 2. encodeBitmap()  — from present fields; auto secondary
//!              └─ 3. encodeFields()  — length prefixes + data per spec
//! ```
//!
//! ## Usage
//!
//! ```zig
//! var msg = try iso8583.Message.init(allocator, &iso8583.SpecV1987);
//! defer msg.deinit();
//!
//! setMti(&msg, 0, .authorization, .request, .acquirer);
//! try setField(&msg, 2, "4111111111111111");
//! try setField(&msg, 4, "000000001000");
//!
//! var buf = std.ArrayList(u8).init(allocator);
//! defer buf.deinit();
//! try iso8583.encode(&msg, buf.writer());
//! // buf.items is now the wire-format message
//! ```
//!
//! ## Field Ordering
//!
//! Fields are written in ascending field-ID order, matching bitmap order.
//! Variable-length fields get their ASCII length prefix (2/3/4 digits)
//! prepended automatically. Fixed-length fields are written as-is.

const std = @import("std");
const spec_mod = @import("spec.zig");
const bitmap_mod = @import("bitmap.zig");
const mti_mod = @import("mti.zig");
const field_mod = @import("field.zig");
const encoding = @import("encoding.zig");
const simd = @import("simd.zig");
const decoder = @import("decoder.zig");

pub const Message = decoder.Message;
pub const Spec = spec_mod.Spec;
pub const Bitmap = bitmap_mod.Bitmap;
pub const Mti = mti_mod.Mti;
pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

// ─── Error Set ─────────────────────────────────────────────────────────────

/// Errors that can occur during encoding or field setting.
pub const EncodeError = error{
    /// Field ID is not defined in the message's spec.
    FieldNotInSpec,
    /// Variable-length data exceeds the spec's max_len.
    FieldTooLong,
    /// Fixed-length data does not exactly match the spec length.
    FieldNotSet,
    /// BCD conversion failed on invalid input.
    InvalidBcdDigit,
    /// Output buffer exhausted.
    BufferTooShort,
    /// Writer allocation failed.
    OutOfMemory,
};

// ─── Encoder ───────────────────────────────────────────────────────────────

/// Encode a Message to a writer.
///
/// Writes MTI, bitmap, and all present fields in ascending field-ID order.
/// The writer can be anything accepting `writeAll` (ArrayList writer,
/// fixedBufferStream, file writer, etc.).
pub fn encode(msg: *const Message, writer: anytype) !void {
    // 1. Encode MTI
    try encodeMti(msg, writer);

    // 2. Encode Bitmap
    try encodeBitmap(msg, writer);

    // 3. Encode fields
    try encodeFields(msg, writer);
}

/// Encode the MTI.
fn encodeMti(msg: *const Message, writer: anytype) !void {
    switch (msg.spec.mti_encoding) {
        .ascii => {
            const ascii = msg.mti.toAscii();
            try writer.writeAll(&ascii);
        },
        .bcd => {
            const bcd = try msg.mti.toBcd();
            try writer.writeAll(&bcd);
        },
    }
}

/// Encode the bitmap.
fn encodeBitmap(msg: *const Message, writer: anytype) !void {
    // Build bitmap from present fields
    var bm = Bitmap.init();
    var iter = msg.field_store.iterator();
    while (iter.next()) |field_id| {
        bm.set(field_id);
    }

    switch (msg.spec.bitmap_encoding) {
        .binary => {
            var out: [16]u8 = undefined;
            const len = try bm.encode(&out);
            try writer.writeAll(out[0..len]);
        },
        .bcd => {
            // BCD bitmap: each byte → 2 hex ASCII digits
            var out: [16]u8 = undefined;
            const len = try bm.encode(&out);

            var bcd_buf: [32]u8 = undefined;
            simd.bcdToAscii(out[0..len], &bcd_buf);
            try writer.writeAll(bcd_buf[0 .. len * 2]);
        },
    }
}

/// Encode all present fields.
fn encodeFields(msg: *const Message, writer: anytype) !void {
    var iter = msg.field_store.iterator();
    while (iter.next()) |field_id| {
        const desc = msg.spec.lookupRuntime(field_id) orelse continue;
        const data = msg.field_store.get(field_id) orelse continue;
        try encodeField(writer, data, desc);
    }
}

/// Encode a single field.
fn encodeField(writer: anytype, data: []const u8, desc: spec_mod.FieldDescriptor) !void {
    // Write length prefix for variable-length fields
    switch (desc.length_type) {
        .llvar, .lllvar => {
            const prefix_digits = desc.length_type.prefixDigits().?;
            var prefix_buf: [4]u8 = undefined;
            encoding.writeAsciiUint(data.len, prefix_buf[4 - prefix_digits .. 4]);
            try writer.writeAll(prefix_buf[4 - prefix_digits .. 4]);
        },
        .llllvar => {
            var prefix_buf: [4]u8 = undefined;
            encoding.writeAsciiUint(data.len, &prefix_buf);
            try writer.writeAll(&prefix_buf);
        },
        else => {},
    }

    // Write field data
    try writer.writeAll(data);
}

// ─── Message Builder Helpers ───────────────────────────────────────────────

/// Set the MTI on a message using structured fields.
///
/// ```zig
/// // Builds MTI "0200": version 0, financial, request, from acquirer
/// setMti(&msg, 0, .financial, .request, .acquirer);
/// ```
pub fn setMti(msg: *Message, version: u4, class: mti_mod.MsgClass, function: mti_mod.MsgFunction, origin: mti_mod.MsgOrigin) void {
    msg.mti = .{
        .version = version,
        .class = class,
        .function = function,
        .origin = origin,
    };
}

/// Set a fixed-length field with automatic padding, allocated from the
/// message's arena (freed with the message).
///
/// - `ascii_numeric`: **right-aligned**, '0'-padded — `setFieldPadded(&msg, 4, "1000")`
///   stores `"000000001000"` for a fixed_12 DE4 (ISO numeric convention).
/// - other encodings: **left-aligned**, ' '-padded — `setFieldPadded(&msg, 41, "T1")`
///   stores `"T1      "` for a fixed_8 DE41 (ISO alphanumeric convention).
///
/// This is the ergonomic counterpart to `setField`, which requires callers
/// to supply exactly `fixedLen` bytes — convenient for hand-built responses,
/// explicit enough that no padding happens silently.
///
/// ## Errors
/// - `error.FieldNotInSpec` — field_id not defined in the spec
/// - `error.NotFixedLength` — field is variable-length (use `setField`)
/// - `error.InvalidFieldLength` — value longer than the field's fixed length
/// - `error.OutOfMemory` — arena allocation failed
pub fn setFieldPadded(msg: *Message, field_id: usize, value: []const u8) !void {
    const desc = msg.spec.lookupRuntime(field_id) orelse return error.FieldNotInSpec;
    const digits = desc.length_type.fixedLen() orelse return error.NotFixedLength;
    // BCD fields carry ceil(digits/2) wire bytes; padding applies to digits.
    const wire_len = switch (desc.encoding) {
        .bcd => (digits + 1) / 2,
        else => digits,
    };
    if (value.len > wire_len) return error.InvalidFieldLength;

    const buf = try msg.arena.allocator().alloc(u8, wire_len);
    switch (desc.encoding) {
        .ascii_numeric => {
            @memset(buf, '0');
            @memcpy(buf[wire_len - value.len ..], value);
        },
        else => {
            @memset(buf, ' ');
            @memcpy(buf[0..value.len], value);
        },
    }
    try setField(msg, field_id, buf);
}

/// Set a fixed-length `ascii_numeric` field from an integer, zero-padded to
/// the field's length (allocated from the message's arena).
///
/// ```zig
/// try setFieldInt(&msg, 4, 1000); // DE4 fixed_12 → "000000001000"
/// ```
///
/// ## Errors
/// - `error.FieldNotInSpec` — field_id not defined in the spec
/// - `error.NotFixedLength` — field is variable-length
/// - `error.NotNumericField` — field is not `ascii_numeric` on the wire
/// - `error.Overflow` — value does not fit in the field's length
/// - `error.OutOfMemory` — arena allocation failed
pub fn setFieldInt(msg: *Message, field_id: usize, value: u64) !void {
    const desc = msg.spec.lookupRuntime(field_id) orelse return error.FieldNotInSpec;
    const digits = desc.length_type.fixedLen() orelse return error.NotFixedLength;
    if (desc.encoding != .ascii_numeric) return error.NotNumericField;

    // cheap width check before allocating
    var tmp: [20]u8 = undefined;
    const written = std.fmt.formatIntBuf(&tmp, value, 10, .lower, .{});
    if (written > digits) return error.Overflow;

    const buf = try msg.arena.allocator().alloc(u8, digits);
    encoding.writeAsciiUint(value, buf); // right-aligned, zero-padded
    try setField(msg, field_id, buf);
}

/// Set a field's data on the message, validating against the spec.
///
/// - Variable-length fields: `data.len` must be <= spec max_len.
/// - Fixed-length fields: `data.len` must exactly equal the spec length.
///   (BCD fields expect wire bytes: ceil(digits / 2).)
///
/// `ascii_numeric` data is additionally pre-parsed into an int (see
/// `Message.getFieldInt`).
///
/// ## Errors
/// - `error.FieldNotInSpec` — field_id not defined in the spec
/// - `error.FieldTooLong` — variable-length data exceeds max_len
/// - `error.InvalidFieldLength` — fixed-length data size mismatch
pub fn setField(msg: *Message, field_id: usize, data: []const u8) !void {
    if (!msg.spec.hasField(field_id)) return error.FieldNotInSpec;

    const desc = msg.spec.lookupRuntime(field_id).?;

    // Validate length for variable-length fields
    if (desc.length_type.isVariable()) {
        if (desc.max_len > 0 and data.len > desc.max_len)
            return error.FieldTooLong;
    } else {
        // For fixed-length fields, data must match expected length
        const expected = desc.length_type.fixedLen().?;
        // For BCD encoding, wire length is half the digit count
        const wire_len = switch (desc.encoding) {
            .bcd => (expected + 1) / 2,
            else => expected,
        };
        if (data.len != wire_len)
            return error.InvalidFieldLength;
    }

    // Pre-parse numeric values
    var int_val: ?u64 = null;
    switch (desc.encoding) {
        .ascii_numeric => {
            if (data.len > 0 and data.len <= 19) {
                int_val = encoding.parseAsciiUint(u64, data) catch null;
            }
        },
        else => {},
    }

    msg.field_store.set(field_id, data, int_val);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "encode simple message" {
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

    var msg = try Message.init(std.testing.allocator, &test_spec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 7, "0606123456");
    try setField(&msg, 11, "000001");
    try setField(&msg, 41, "TERM001 ");
    try setField(&msg, 49, "840");

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try encode(&msg, buf.writer());

    // Verify the encoded message starts with the MTI
    try std.testing.expectEqualSlices(u8, "0100", buf.items[0..4]);
}

test "round-trip encode/decode" {
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

    // Encode
    var msg = try Message.init(std.testing.allocator, &test_spec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 7, "0606123456");
    try setField(&msg, 11, "000001");
    try setField(&msg, 41, "TERM001 ");
    try setField(&msg, 49, "840");

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try encode(&msg, buf.writer());

    // Decode
    var msg2 = try Message.init(std.testing.allocator, &test_spec);
    defer msg2.deinit();
    try msg2.decode(buf.items);

    // Verify
    try std.testing.expectEqual(mti_mod.MsgClass.authorization, msg2.mti.class);
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg2.getField(2).?);
    try std.testing.expectEqualSlices(u8, "000000", msg2.getField(3).?);
    try std.testing.expectEqualSlices(u8, "000000001000", msg2.getField(4).?);
    try std.testing.expectEqualSlices(u8, "TERM001 ", msg2.getField(41).?);
    try std.testing.expectEqualSlices(u8, "840", msg2.getField(49).?);

    // Re-encode and compare
    var buf2 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf2.deinit();
    try encode(&msg2, buf2.writer());

    try std.testing.expectEqualSlices(u8, buf.items, buf2.items);
}
