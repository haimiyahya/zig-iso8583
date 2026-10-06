//! # ISO 8583 Bitmap Encode/Decode
//!
//! ISO 8583 uses a 64-bit (primary) or 128-bit (primary + secondary) bitmap
//! to indicate which data elements are present in a message.
//!
//! ## Bitmap Layout (big-endian, MSB = field 1)
//!
//! ```
//! Byte 0, bit 7 → field 1  (secondary bitmap indicator)
//! Byte 0, bit 6 → field 2  (PAN)
//! Byte 0, bit 5 → field 3
//! ...
//! Byte 7, bit 0 → field 8
//! Byte 8, bit 7 → field 9  (if secondary bitmap present)
//! ...
//! Byte 15, bit 0 → field 64
//! ```
//!
//! **Bit 1** of the primary bitmap is the secondary bitmap indicator:
//! - Set → secondary bitmap (bytes 8–15) follows, covering fields 65–128
//! - Clear → only primary bitmap (bytes 0–7), fields 65–128 are absent
//!
//! Field numbering is 1-based. Field 0 does not exist.
//!
//! ## Usage
//!
//! ```zig
//! var bm = Bitmap.init();
//! bm.set(2);   // Mark field 2 (PAN) as present
//! bm.set(48);  // Mark field 48 as present
//! try std.testing.expect(bm.isPresent(2));
//!
//! // Encode to wire format
//! var out: [16]u8 = undefined;
//! const len = try bm.encode(&out); // Returns 8 or 16
//!
//! // Parse from wire format
//! const result = try Bitmap.parse(out[0..len]);
//!
//! // Iterate present fields
//! var iter = bm.iterator();
//! while (iter.next()) |field_id| { ... }
//! ```

const std = @import("std");
const simd = @import("simd.zig");

/// Maximum number of fields in a standard ISO 8583 message.
pub const MAX_FIELDS: comptime_int = 128;

/// Bitmap structure. Stores the raw 16 bytes and provides access methods.
pub const Bitmap = struct {
    raw: [16]u8,

    const Self = @This();

    /// Create a zero-initialized bitmap (no fields present).
    pub fn init() Bitmap {
        return .{ .raw = .{0} ** 16 };
    }

    /// Parse a bitmap from a byte slice. Reads at least 8 bytes (primary bitmap).
    /// If bit 1 is set, reads an additional 8 bytes (secondary bitmap).
    /// Returns the parsed bitmap and the number of bytes consumed.
    pub fn parse(buf: []const u8) !struct { bitmap: Bitmap, consumed: usize } {
        if (buf.len < 8) return error.BufferTooShort;

        var bm = Bitmap.init();
        @memcpy(bm.raw[0..8], buf[0..8]);

        // Check if secondary bitmap is present (bit 1 = MSB of byte 0)
        if (bm.isPresent(1)) {
            if (buf.len < 16) return error.BufferTooShort;
            @memcpy(bm.raw[8..16], buf[8..16]);
            return .{ .bitmap = bm, .consumed = 16 };
        }

        return .{ .bitmap = bm, .consumed = 8 };
    }

    /// Check if a field (1-based) is present in the bitmap.
    pub fn isPresent(self: Self, field_id: usize) bool {
        if (field_id < 1 or field_id > MAX_FIELDS) return false;
        const bit_idx = field_id - 1; // 0-based
        const byte_idx = bit_idx / 8;
        const bit_in_byte: u3 = @intCast(7 - (bit_idx % 8));
        return (self.raw[byte_idx] & (@as(u8, 1) << bit_in_byte)) != 0;
    }

    /// Set a field (1-based) as present in the bitmap.
    pub fn set(self: *Self, field_id: usize) void {
        if (field_id < 1 or field_id > MAX_FIELDS) return;
        const bit_idx = field_id - 1;
        const byte_idx = bit_idx / 8;
        const bit_in_byte: u3 = @intCast(7 - (bit_idx % 8));
        self.raw[byte_idx] |= (@as(u8, 1) << bit_in_byte);
    }

    /// Clear a field (1-based) from the bitmap.
    pub fn unset(self: *Self, field_id: usize) void {
        if (field_id < 1 or field_id > MAX_FIELDS) return;
        const bit_idx = field_id - 1;
        const byte_idx = bit_idx / 8;
        const bit_in_byte: u3 = @intCast(7 - (bit_idx % 8));
        self.raw[byte_idx] &= ~(@as(u8, 1) << bit_in_byte);
    }

    /// Returns true if a secondary bitmap is needed (any field 65–128 is set).
    pub fn needsSecondary(self: Self) bool {
        for (self.raw[8..16]) |byte| {
            if (byte != 0) return true;
        }
        return false;
    }

    /// Count the number of present fields (using SIMD popcount).
    pub fn countPresent(self: Self) u32 {
        return simd.countPresentFields(&self.raw);
    }

    /// Return the presence array for all 128 fields.
    pub fn presenceArray(self: Self) [MAX_FIELDS]bool {
        // simd returns [128]bool indexed from 0 = bit position
        const arr = simd.decodeBitmapPresence(&self.raw);
        // Shift: our array is 1-indexed conceptually, but stored 0-indexed
        // arr[0] = bit position 0 = field 1, arr[1] = field 2, etc.
        return arr;
    }

    /// Encode the bitmap to bytes. Returns 8 or 16 bytes depending on
    /// whether a secondary bitmap is needed.
    /// Writes into `out` and returns the number of bytes written.
    pub fn encode(self: Self, out: []u8) !usize {
        const need_secondary = self.needsSecondary();
        const len: usize = if (need_secondary) 16 else 8;
        if (out.len < len) return error.BufferTooShort;

        @memcpy(out[0..len], self.raw[0..len]);

        // Ensure bit 1 correctly reflects secondary bitmap presence
        if (need_secondary) {
            out[0] |= 0x80;
        } else {
            out[0] &= 0x7F;
        }

        return len;
    }

    /// Iterator over present field IDs (1-based).
    pub const Iterator = struct {
        bitmap: *const Bitmap,
        next_field: usize, // 1-based, next field to check

        pub fn init(bitmap: *const Bitmap) Iterator {
            return .{ .bitmap = bitmap, .next_field = 2 }; // Start at field 2 (skip bitmap indicator)
        }

        pub fn next(self: *Iterator) ?usize {
            while (self.next_field <= MAX_FIELDS) {
                const field_id = self.next_field;
                self.next_field += 1;
                if (self.bitmap.isPresent(field_id)) {
                    return field_id;
                }
            }
            return null;
        }
    };

    pub fn iterator(self: *const Bitmap) Iterator {
        return Iterator.init(self);
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

test "Bitmap.init" {
    const bm = Bitmap.init();
    for (0..MAX_FIELDS) |i| {
        try std.testing.expect(!bm.isPresent(i + 1));
    }
}

test "Bitmap set/isPresent/unset" {
    var bm = Bitmap.init();
    bm.set(2);
    try std.testing.expect(bm.isPresent(2));
    try std.testing.expect(!bm.isPresent(3));
    bm.set(65);
    try std.testing.expect(bm.isPresent(65));
    bm.unset(2);
    try std.testing.expect(!bm.isPresent(2));
}

test "Bitmap.parse primary only" {
    // Primary bitmap: bit 2 set → 0x40 0x00 ... 0x00
    const buf = [_]u8{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = try Bitmap.parse(&buf);
    try std.testing.expectEqual(@as(usize, 8), result.consumed);
    try std.testing.expect(result.bitmap.isPresent(2));
    try std.testing.expect(!result.bitmap.isPresent(1));
}

test "Bitmap.parse with secondary" {
    // Bit 1 set (0x80) + bit 2 set (0x40) in primary
    // Bit 65 set (0x80) in secondary
    const buf = [_]u8{
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // primary
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // secondary
    };
    const result = try Bitmap.parse(&buf);
    try std.testing.expectEqual(@as(usize, 16), result.consumed);
    try std.testing.expect(result.bitmap.isPresent(1)); // secondary indicator
    try std.testing.expect(result.bitmap.isPresent(2));
    try std.testing.expect(result.bitmap.isPresent(65));
}

test "Bitmap.parse buffer too short" {
    const buf = [_]u8{0x80}; // Needs secondary but only 1 byte
    try std.testing.expectError(error.BufferTooShort, Bitmap.parse(&buf));
}

test "Bitmap.needsSecondary" {
    var bm = Bitmap.init();
    try std.testing.expect(!bm.needsSecondary());
    bm.set(65);
    try std.testing.expect(bm.needsSecondary());
}

test "Bitmap.encode primary only" {
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(4);
    var out: [16]u8 = undefined;
    const len = try bm.encode(&out);
    try std.testing.expectEqual(@as(usize, 8), len);
    // Bit 2 = 0x40, Bit 4 = 0x10 → byte 0 = 0x50
    try std.testing.expectEqual(@as(u8, 0x50), out[0]);
}

test "Bitmap.encode with secondary" {
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(65);
    var out: [16]u8 = undefined;
    const len = try bm.encode(&out);
    try std.testing.expectEqual(@as(usize, 16), len);
    // Bit 1 should be auto-set, bit 2 set → byte 0 = 0xC0
    try std.testing.expectEqual(@as(u8, 0xC0), out[0]);
    // Bit 65 → byte 8 = 0x80
    try std.testing.expectEqual(@as(u8, 0x80), out[8]);
}

test "Bitmap round-trip" {
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(7);
    bm.set(11);
    bm.set(12);
    bm.set(65);
    bm.set(100);

    var out: [16]u8 = undefined;
    const len = try bm.encode(&out);

    const result = try Bitmap.parse(out[0..len]);
    try std.testing.expect(result.bitmap.isPresent(2));
    try std.testing.expect(result.bitmap.isPresent(3));
    try std.testing.expect(result.bitmap.isPresent(4));
    try std.testing.expect(result.bitmap.isPresent(7));
    try std.testing.expect(result.bitmap.isPresent(11));
    try std.testing.expect(result.bitmap.isPresent(12));
    try std.testing.expect(result.bitmap.isPresent(65));
    try std.testing.expect(result.bitmap.isPresent(100));
    try std.testing.expect(!result.bitmap.isPresent(5));
}

test "Bitmap.iterator" {
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(4);
    bm.set(7);

    var iter = bm.iterator();
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, 4), iter.next());
    try std.testing.expectEqual(@as(?usize, 7), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "Bitmap.countPresent" {
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(4);
    bm.set(7);
    try std.testing.expectEqual(@as(u32, 3), bm.countPresent());
}
