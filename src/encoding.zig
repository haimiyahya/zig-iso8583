//! # Field Encoding Types and Codec Functions
//!
//! Defines wire-encoding types and provides scalar (non-SIMD) implementations
//! of BCD↔ASCII conversion, ASCII numeric parsing, length-prefix handling,
//! and validation.
//!
//! For SIMD-accelerated versions, see `simd.zig`. The functions here serve as
//! scalar fallbacks for sub-vector tails and platforms without SIMD support.
//!
//! ## Types
//!
//! **FieldEncoding** — How field data is encoded on the wire:
//!   - `ascii_numeric`: ASCII digits '0'–'9' (DE2 PAN, DE4 Amount, DE11 STAN)
//!   - `ascii_alpha`: ASCII alphanumeric A-Z, a-z, 0-9 (DE41, DE48)
//!   - `ascii_binary`: ASCII hex 0-9, A-F, a-f (some sub-field encodings)
//!   - `bcd`: Binary Coded Decimal, 2 digits/byte (BCD MTI, BCD bitmap)
//!   - `binary`: Raw bytes (DE52 PIN block, DE64 MAC)
//!
//! **LengthType** — How field length is determined:
//!   - `fixed_N`: Exactly N bytes (DE3=6, DE4=12, DE41=8)
//!   - `llvar`: 2-digit ASCII length prefix (DE2, DE33)
//!   - `lllvar`: 3-digit ASCII length prefix (DE48, DE62)
//!   - `llllvar`: 4-digit ASCII length prefix (rare)

const std = @import("std");

// ─── Encoding Enums ────────────────────────────────────────────────────────

/// How a field's data is encoded on the wire.
pub const FieldEncoding = enum {
    /// ASCII digits '0'–'9'. Each digit occupies one byte (0x30–0x39).
    ascii_numeric,
    /// ASCII alphanumeric: A-Z, a-z, 0-9.
    ascii_alpha,
    /// ASCII hex: 0-9, A-F, a-f. Two hex chars per byte.
    ascii_binary,
    /// Binary Coded Decimal: two digits packed per byte.
    /// High nibble = first digit, low nibble = second digit.
    bcd,
    /// Raw binary bytes with no character interpretation.
    binary,

    /// Returns true if this encoding uses ASCII representation on the wire.
    pub fn isAscii(self: FieldEncoding) bool {
        return switch (self) {
            .ascii_numeric, .ascii_alpha, .ascii_binary => true,
            .bcd, .binary => false,
        };
    }

    /// Returns true if this encoding is Binary Coded Decimal.
    pub fn isBcd(self: FieldEncoding) bool {
        return self == .bcd;
    }
};

/// How a field's length is specified on the wire.
pub const LengthType = enum(u8) {
    fixed_1 = 1,
    fixed_2 = 2,
    fixed_3 = 3,
    fixed_4 = 4,
    fixed_5 = 5,
    fixed_6 = 6,
    fixed_7 = 7,
    fixed_8 = 8,
    fixed_10 = 10,
    fixed_12 = 12,
    fixed_15 = 15,
    fixed_16 = 16,
    fixed_20 = 20,
    fixed_24 = 24,
    fixed_28 = 28,
    fixed_32 = 32,
    fixed_35 = 35,
    fixed_36 = 36,
    fixed_40 = 40,
    fixed_41 = 41,
    fixed_42 = 42,
    fixed_48 = 48,
    fixed_52 = 52,
    fixed_56 = 56,
    fixed_64 = 64,
    fixed_76 = 76,
    fixed_80 = 80,
    fixed_96 = 96,
    fixed_100 = 100,
    fixed_128 = 128,
    /// Variable-length: 1-byte BINARY big-endian length prefix (legacy
    /// GHL UAISOMM terminal dialect: DE2/DE35 len="1").
    bvar1,
    /// Variable-length: 2-byte BINARY big-endian length prefix.
    bvar2,
    /// Variable-length: 3-byte BINARY big-endian length prefix
    /// (MEPS-ISOB24 DE48/DE55/DE123 len="3").
    bvar3,
    /// Variable-length: 1 ASCII digit length prefix.
    lvar,
    /// Variable-length: 2 ASCII digit length prefix.
    llvar,
    /// Variable-length: 3 ASCII digit length prefix.
    lllvar,
    /// Variable-length: 4 ASCII digit length prefix.
    llllvar,

    /// Returns the number of bytes in a binary length prefix, or null for
    /// ASCII-digit / fixed-length types.
    pub fn prefixBytes(self: LengthType) ?usize {
        return switch (self) {
            .bvar1 => 1,
            .bvar2 => 2,
            .bvar3 => 3,
            else => null,
        };
    }

    /// Returns the fixed byte length, or null for variable-length types.
    pub fn fixedLen(self: LengthType) ?usize {
        return switch (self) {
            .bvar1, .bvar2, .bvar3, .lvar, .llvar, .lllvar, .llllvar => null,
            else => @intFromEnum(self),
        };
    }

    /// Returns the number of digits in the length prefix for variable-length fields.
    /// lvar→1, llvar→2, lllvar→3, llllvar→4, binary prefixes→null, fixed→null.
    pub fn prefixDigits(self: LengthType) ?u3 {
        return switch (self) {
            .lvar => 1,
            .llvar => 2,
            .lllvar => 3,
            .llllvar => 4,
            else => null,
        };
    }

    /// Returns true if this is a variable-length type.
    pub fn isVariable(self: LengthType) bool {
        return self.fixedLen() == null;
    }
};

// ─── BCD Codec ─────────────────────────────────────────────────────────────

/// Decode a single BCD byte into two ASCII digit bytes.
/// Example: bcdByteToAscii(0x12) returns { '1', '2' }
pub fn bcdByteToAscii(bcd: u8) [2]u8 {
    const hi: u8 = (bcd >> 4) & 0x0F;
    const lo: u8 = bcd & 0x0F;
    return .{ hi + 0x30, lo + 0x30 };
}

/// Encode two ASCII digit bytes into a single BCD byte.
/// Returns error.InvalidBcdDigit if either byte is not '0'–'9'.
/// Example: asciiToBcdByte('1', '2') returns 0x12
pub fn asciiToBcdByte(hi: u8, lo: u8) !u8 {
    if (hi < 0x30 or hi > 0x39 or lo < 0x30 or lo > 0x39)
        return error.InvalidBcdDigit;
    return ((hi - 0x30) << 4) | (lo - 0x30);
}

/// Decode BCD bytes into ASCII digits (scalar fallback).
/// Each BCD byte produces two ASCII bytes in `out`.
/// Caller must ensure out.len >= bcd.len * 2.
pub fn bcdToAscii(bcd: []const u8, out: []u8) void {
    for (bcd, 0..) |byte, i| {
        const digits = bcdByteToAscii(byte);
        out[i * 2] = digits[0];
        out[i * 2 + 1] = digits[1];
    }
}

/// Encode ASCII digits into BCD bytes (scalar fallback).
/// Pairs of ASCII chars → single BCD byte. ascii.len must be even.
pub fn asciiToBcd(ascii: []const u8, out: []u8) !void {
    if (ascii.len % 2 != 0) return error.InvalidBcdDigit;
    var i: usize = 0;
    while (i < ascii.len / 2) : (i += 1) {
        out[i] = try asciiToBcdByte(ascii[i * 2], ascii[i * 2 + 1]);
    }
}

// ─── ASCII Numeric Parsing ─────────────────────────────────────────────────

/// Parse an ASCII numeric string into an integer of type T.
/// All bytes must be '0'–'9'. Returns error.InvalidFieldEncoding for
/// non-digits or empty input, error.Overflow if value exceeds maxInt(T).
pub fn parseAsciiUint(comptime T: type, buf: []const u8) !T {
    if (buf.len == 0) return error.InvalidFieldEncoding;
    var result: T = 0;
    for (buf) |b| {
        if (b < 0x30 or b > 0x39) return error.InvalidFieldEncoding;
        if (result != 0 and result > std.math.maxInt(T) / 10)
            return error.Overflow;
        result *%= 10;
        const digit: T = @intCast(b - 0x30);
        if (result > std.math.maxInt(T) - digit)
            return error.Overflow;
        result +%= digit;
    }
    return result;
}

/// Write a u64 value as zero-padded ASCII digits into buf.
/// Right-aligned: writeAsciiUint(42, buf[0..6]) → "000042"
pub fn writeAsciiUint(value: u64, buf: []u8) void {
    var v = value;
    var i: usize = buf.len;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast((v % 10) + 0x30);
        v /= 10;
    }
}

// ─── Length Prefix Codec ───────────────────────────────────────────────────

/// Parse a variable-length field's length prefix.
/// Reads prefix_digits (2/3/4) ASCII bytes, returns .len and .consumed.
pub fn parseLengthPrefix(buf: []const u8, prefix_digits: u3) !struct { len: usize, consumed: usize } {
    if (buf.len < prefix_digits) return error.BufferTooShort;
    const len = try parseAsciiUint(usize, buf[0..prefix_digits]);
    return .{ .len = len, .consumed = prefix_digits };
}

/// Write a variable-length field's length prefix into the buffer.
pub fn writeLengthPrefix(buf: []u8, len: usize, comptime prefix_digits: u3) void {
    var tmp: [4]u8 = undefined;
    writeAsciiUint(len, &tmp);
    @memcpy(buf[0..prefix_digits], tmp[4 - prefix_digits .. 4]);
}

// ─── Validation ────────────────────────────────────────────────────────────

/// Validate that all bytes are ASCII digits '0'–'9' (scalar).
pub fn validateAsciiDigitsScalar(slice: []const u8) bool {
    for (slice) |b| {
        if (b < 0x30 or b > 0x39) return false;
    }
    return true;
}

/// Validate that all bytes are ASCII alphanumeric A-Z, a-z, 0-9 (scalar).
pub fn validateAsciiAlnumScalar(slice: []const u8) bool {
    for (slice) |b| {
        const is_digit = b >= 0x30 and b <= 0x39;
        const is_upper = b >= 0x41 and b <= 0x5A;
        const is_lower = b >= 0x61 and b <= 0x7A;
        if (!is_digit and !is_upper and !is_lower) return false;
    }
    return true;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "bcdByteToAscii" {
    const result = bcdByteToAscii(0x12);
    try std.testing.expectEqual(@as(u8, '1'), result[0]);
    try std.testing.expectEqual(@as(u8, '2'), result[1]);
    const result2 = bcdByteToAscii(0x99);
    try std.testing.expectEqual(@as(u8, '9'), result2[0]);
    try std.testing.expectEqual(@as(u8, '9'), result2[1]);
}

test "asciiToBcdByte" {
    try std.testing.expectEqual(@as(u8, 0x12), try asciiToBcdByte('1', '2'));
    try std.testing.expectEqual(@as(u8, 0x99), try asciiToBcdByte('9', '9'));
}

test "asciiToBcdByte invalid" {
    try std.testing.expectError(error.InvalidBcdDigit, asciiToBcdByte('A', '2'));
    try std.testing.expectError(error.InvalidBcdDigit, asciiToBcdByte('1', 'X'));
}

test "bcdToAscii / asciiToBcd round-trip" {
    const bcd_input = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90 };
    var ascii_buf: [10]u8 = undefined;
    bcdToAscii(&bcd_input, &ascii_buf);
    try std.testing.expectEqualSlices(u8, "1234567890", &ascii_buf);
    var bcd_out: [5]u8 = undefined;
    try asciiToBcd(&ascii_buf, &bcd_out);
    try std.testing.expectEqualSlices(u8, &bcd_input, &bcd_out);
}

test "parseAsciiUint" {
    try std.testing.expectEqual(@as(u64, 12345), try parseAsciiUint(u64, "12345"));
    try std.testing.expectEqual(@as(u64, 0), try parseAsciiUint(u64, "0"));
}

test "writeAsciiUint" {
    var buf: [12]u8 = undefined;
    writeAsciiUint(12345, &buf);
    try std.testing.expectEqualSlices(u8, "000000012345", &buf);
}

test "validateAsciiDigitsScalar" {
    try std.testing.expect(validateAsciiDigitsScalar("12345"));
    try std.testing.expect(!validateAsciiDigitsScalar("123A5"));
}

test "validateAsciiAlnumScalar" {
    try std.testing.expect(validateAsciiAlnumScalar("ABC123"));
    try std.testing.expect(!validateAsciiAlnumScalar("ABC 123"));
}

test "LengthType.fixedLen" {
    try std.testing.expectEqual(@as(?usize, 6), LengthType.fixed_6.fixedLen());
    try std.testing.expectEqual(@as(?usize, null), LengthType.llvar.fixedLen());
}

test "LengthType.prefixDigits" {
    try std.testing.expectEqual(@as(?u3, 2), LengthType.llvar.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 3), LengthType.lllvar.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 4), LengthType.llllvar.prefixDigits());
}
