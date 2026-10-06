//! Zero-copy slice view types for ISO 8583 fields.
//!
//! Provides typed views into a source buffer without copying data.
//! The caller must ensure the source buffer outlives the views.

const std = @import("std");
const encoding = @import("encoding.zig");
const spec_mod = @import("spec.zig");
const field_mod = @import("field.zig");

pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

// ─── Field View ────────────────────────────────────────────────────────────

/// A zero-copy view of a decoded field.
/// `raw` is a slice into the original message buffer.
pub const FieldView = struct {
    field_id: u8,
    enc: FieldEncoding,
    length_type: LengthType,
    /// Byte slice into the original message buffer — zero copy.
    raw: []const u8,
    /// Pre-parsed integer value for numeric fields.
    int_val: ?u64 = null,

    const Self = @This();

    /// Parse the field as an integer of the given type.
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

    /// Return the length of the field data.
    pub fn len(self: Self) usize {
        return self.raw.len;
    }

    /// Check if this is a variable-length field.
    pub fn isVariable(self: Self) bool {
        return self.length_type.isVariable();
    }
};

// ─── Message Buffer ────────────────────────────────────────────────────────

/// A message buffer that can be used for both decoding and encoding.
/// Provides a stable backing store for zero-copy field views.
pub const MessageBuffer = struct {
    data: []const u8,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{ .data = data };
    }

    /// Get a slice into the buffer. Validates bounds.
    pub fn slice(self: Self, start: usize, length: usize) ?[]const u8 {
        if (start + length > self.data.len) return null;
        return self.data[start .. start + length];
    }

    /// Get the total length of the buffer.
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
