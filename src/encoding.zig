//! Field encoding types and codec functions for ISO 8583.
//!
//! Supports BCD, ASCII numeric, ASCII alpha, ASCII binary, and binary encodings.
//! SIMD-accelerated conversion functions are in simd.zig; this module provides
//! the type definitions and scalar (fallback) codec implementations.

const std = @import("std");

// ─── Encoding Enums ────────────────────────────────────────────────────────

/// How a field's data is encoded on the wire.
pub const FieldEncoding = enum {
    ascii_numeric, // ASCII digits '0'–'9'
    ascii_alpha, // ASCII alphanumeric
    ascii_binary, // ASCII hex representation of binary
    bcd, // Binary Coded Decimal (2 digits per byte)
    binary, // Raw bytes

    /// Returns true if this encoding uses ASCII representation.
    pub fn isAscii(self: FieldEncoding) bool {
        return switch (self) {
            .ascii_numeric, .ascii_alpha, .ascii_binary => true,
            .bcd, .binary => false,
        };
    }

    /// Returns true if this encoding is BCD.
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
    llvar, // 2-digit length prefix
    lllvar, // 3-digit length prefix
    llllvar, // 4-digit length prefix (rare)

    /// Returns the fixed byte length, or null for variable-length types.
    pub fn fixedLen(self: LengthType) ?usize {
        return switch (self) {
            .llvar, .lllvar, .llllvar => null,
            else => @intFromEnum(self),
        };
    }

    /// Returns the number of digits in the length prefix for variable-length fields.
    pub fn prefixDigits(self: LengthType) ?u3 {
        return switch (self) {
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
/// Example: 0xAB → 'A', 'B' (i.e., 0x41, 0x42 for A=10, B=11 digit values)
/// For typical financial use: 0x12 → '1', '2' (0x31, 0x32)
pub fn bcdByteToAscii(bcd: u8) [2]u8 {
    const hi: u8 = (bcd >> 4) & 0x0F;
    const lo: u8 = bcd & 0x0F;
    return .{ hi + 0x30, lo + 0x30 };
}

/// Encode two ASCII digit bytes into a single BCD byte.
/// Example: '1', '2' → 0x12
pub fn asciiToBcdByte(hi: u8, lo: u8) !u8 {
    if (hi < 0x30 or hi > 0x39 or lo < 0x30 or lo > 0x39)
        return error.InvalidBcdDigit;
    return ((hi - 0x30) << 4) | (lo - 0x30);
}

/// Decode BCD bytes into ASCII digits (scalar fallback).
/// `bcd.len` bytes produce `bcd.len * 2` ASCII bytes in `out`.
/// `out.len` must be >= `bcd.len * 2`.
pub fn bcdToAscii(bcd: []const u8, out: []u8) void {
    for (bcd, 0..) |byte, i| {
        const digits = bcdByteToAscii(byte);
        out[i * 2] = digits[0];
        out[i * 2 + 1] = digits[1];
    }
}

/// Encode ASCII digits into BCD bytes (scalar fallback).
/// Two ASCII chars produce one BCD byte. `ascii.len` must be even.
pub fn asciiToBcd(ascii: []const u8, out: []u8) !void {
    if (ascii.len % 2 != 0) return error.InvalidBcdDigit;
    var i: usize = 0;
    while (i < ascii.len / 2) : (i += 1) {
        out[i] = try asciiToBcdByte(ascii[i * 2], ascii[i * 2 + 1]);
    }
}

// ─── ASCII Numeric Parsing ─────────────────────────────────────────────────

/// Parse an ASCII numeric string into a u64.
/// All bytes must be ASCII digits '0'–'9'.
pub fn parseAsciiUint(comptime T: type, buf: []const u8) !T {
    if (buf.len == 0) return error.InvalidFieldEncoding;
    var result: T = 0;
    for (buf) |b| {
        if (b < 0x30 or b > 0x39) return error.InvalidFieldEncoding;
        // Check for overflow before multiplying
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

/// Write a u64 value as ASCII digits into `buf`.
/// Right-aligned, zero-padded to `buf.len`.
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

/// Parse a variable-length field's length prefix from the buffer.
/// Returns the parsed length and the number of bytes consumed by the prefix.
pub fn parseLengthPrefix(buf: []const u8, prefix_digits: u3) !struct { len: usize, consumed: usize } {
    if (buf.len < prefix_digits) return error.BufferTooShort;
    const len = try parseAsciiUint(usize, buf[0..prefix_digits]);
    return .{ .len = len, .consumed = prefix_digits };
}

/// Write a variable-length field's length prefix into the buffer.
pub fn writeLengthPrefix(buf: []u8, len: usize, comptime prefix_digits: u2) void {
    var tmp: [4]u8 = undefined;
    writeAsciiUint(len, &tmp);
    @memcpy(buf[0..prefix_digits], tmp[4 - prefix_digits .. 4]);
}

// ─── Validation ────────────────────────────────────────────────────────────

/// Validate that all bytes are ASCII digits (scalar).
pub fn validateAsciiDigitsScalar(slice: []const u8) bool {
    for (slice) |b| {
        if (b < 0x30 or b > 0x39) return false;
    }
    return true;
}

/// Validate that all bytes are ASCII alphanumeric (scalar).
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
    const result = try asciiToBcdByte('1', '2');
    try std.testing.expectEqual(@as(u8, 0x12), result);

    const result2 = try asciiToBcdByte('9', '9');
    try std.testing.expectEqual(@as(u8, 0x99), result2);
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
    try std.testing.expectEqual(@as(u64, 999999999999), try parseAsciiUint(u64, "999999999999"));
}

test "writeAsciiUint" {
    var buf: [12]u8 = undefined;
    writeAsciiUint(12345, &buf);
    try std.testing.expectEqualSlices(u8, "000000012345", &buf);
}

test "validateAsciiDigitsScalar" {
    try std.testing.expect(validateAsciiDigitsScalar("12345"));
    try std.testing.expect(!validateAsciiDigitsScalar("123A5"));
    try std.testing.expect(validateAsciiDigitsScalar(""));
}

test "validateAsciiAlnumScalar" {
    try std.testing.expect(validateAsciiAlnumScalar("ABC123"));
    try std.testing.expect(!validateAsciiAlnumScalar("ABC 123"));
}

test "LengthType.fixedLen" {
    try std.testing.expectEqual(@as(?usize, 6), LengthType.fixed_6.fixedLen());
    try std.testing.expectEqual(@as(?usize, 12), LengthType.fixed_12.fixedLen());
    try std.testing.expectEqual(@as(?usize, null), LengthType.llvar.fixedLen());
    try std.testing.expectEqual(@as(?usize, null), LengthType.lllvar.fixedLen());
}

test "LengthType.prefixDigits" {
    try std.testing.expectEqual(@as(?u3, null), LengthType.fixed_6.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 2), LengthType.llvar.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 3), LengthType.lllvar.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 4), LengthType.llllvar.prefixDigits());
}
