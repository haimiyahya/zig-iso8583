//! # Zero-Copy Slice View Types for ISO 8583 Fields
//!
//! Typed views into a source buffer without copying data.
//!
//! ## `FieldView`
//!
//! A decoded field with typed accessors: `asInt(T)` for numeric conversion
//! and `asBytes()` for raw access. `raw` points into the original message
//! buffer.
//!
//! ## `MessageBuffer`
//!
//! A bounds-checked wrapper over a byte slice, providing `slice(start, len)`
//! with null-on-overflow semantics for safe manual parsing.
//!
//! ## Lifetime Contract
//!
//! Views reference the source buffer. The caller must keep the buffer alive
//! and unmodified for as long as any view derived from it is in use.

const std = @import("std");
const encoding = @import("encoding.zig");
const spec_mod = @import("spec.zig");
const field_mod = @import("field.zig");

pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

// ─── Field View ────────────────────────────────────────────────────────────

/// A zero-copy view of a decoded field with typed accessors.
///
/// `raw` is a slice into the original message buffer — reading it does not
/// copy data. For numeric fields with a pre-parsed value, `asInt` returns
/// it directly; otherwise it parses from ASCII on demand.
pub const FieldView = struct {
    /// Field ID (2–128).
    field_id: u8,
    /// Wire encoding of this field.
    enc: FieldEncoding,
    /// Length type of this field.
    length_type: LengthType,
    /// Byte slice into the original message buffer — zero copy.
    raw: []const u8,
    /// Pre-parsed integer value for numeric fields, if available.
    int_val: ?u64 = null,

    const Self = @This();

    /// Parse the field as an integer of type T.
    ///
    /// Uses the pre-parsed `int_val` when available (narrowing to T),
    /// otherwise parses `raw` as ASCII digits. Returns error.Overflow if
    /// the value does not fit in T.
    pub fn asInt(self: Self, comptime T: type) !T {
        if (self.int_val) |v| {
            return std.math.cast(T, v) orelse error.Overflow;
        }
        return encoding.parseAsciiUint(T, self.raw);
    }

    /// Return the raw bytes as a string slice.
    pub fn asBytes(self: Self) []const u8 {
        return self.raw;
    }

    /// Return the length of the field data in bytes.
    pub fn len(self: Self) usize {
        return self.raw.len;
    }

    /// Check if this is a variable-length field.
    pub fn isVariable(self: Self) bool {
        return self.length_type.isVariable();
    }
};

// ─── Message Buffer ────────────────────────────────────────────────────────

/// A bounds-checked wrapper over a message byte slice.
///
/// Provides safe manual parsing helpers with null-on-overflow semantics.
pub const MessageBuffer = struct {
    /// The underlying message bytes.
    data: []const u8,

    const Self = @This();

    /// Wrap a byte slice as a message buffer.
    pub fn init(data: []const u8) Self {
        return .{ .data = data };
    }

    /// Get a slice into the buffer. Returns null if out of bounds.
    pub fn slice(self: Self, start: usize, length: usize) ?[]const u8 {
        if (start + length > self.data.len) return null;
        return self.data[start .. start + length];
    }

    /// Get the total length of the buffer in bytes.
    pub fn len(self: Self) usize {
        return self.data.len;
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

test "FieldView.asInt" {
    const view = FieldView{
        .field_id = 4,
        .enc = .ascii_numeric,
        .length_type = .fixed_12,
        .raw = "000000001000",
        .int_val = 1000,
    };
    try std.testing.expectEqual(@as(u64, 1000), try view.asInt(u64));
    try std.testing.expectEqual(@as(u32, 1000), try view.asInt(u32));
}

test "FieldView.asBytes" {
    const view = FieldView{
        .field_id = 41,
        .enc = .ascii_alpha,
        .length_type = .fixed_8,
        .raw = "TERM001 ",
        .int_val = null,
    };
    try std.testing.expectEqualSlices(u8, "TERM001 ", view.asBytes());
}

test "MessageBuffer.slice" {
    const buf = MessageBuffer.init("Hello, World!");
    try std.testing.expectEqualSlices(u8, "Hello", buf.slice(0, 5).?);
    try std.testing.expectEqualSlices(u8, "World", buf.slice(7, 5).?);
    try std.testing.expectEqual(@as(?[]const u8, null), buf.slice(10, 10));
}
