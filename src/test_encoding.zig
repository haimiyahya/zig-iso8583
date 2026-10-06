//! Comprehensive tests for the encoding module.
//! Covers BCD codec, ASCII parsing, length prefix, validation, edge cases.

const std = @import("std");
const encoding = @import("encoding.zig");

// ═══════════════════════════════════════════════════════════════════════════
// BCD Byte Codec
// ═══════════════════════════════════════════════════════════════════════════

test "bcdByteToAscii all nibble combinations" {
    // Test every possible nibble value 0-9
    for (0..10) |hi| {
        for (0..10) |lo| {
            const bcd: u8 = @intCast((hi << 4) | lo);
            const result = encoding.bcdByteToAscii(bcd);
            try std.testing.expectEqual(@as(u8, @intCast(hi + 0x30)), result[0]);
            try std.testing.expectEqual(@as(u8, @intCast(lo + 0x30)), result[1]);
        }
    }
}

test "bcdByteToAscii boundary values" {
    // 0x00 → '0','0'
    const r0 = encoding.bcdByteToAscii(0x00);
    try std.testing.expectEqual('0', r0[0]);
    try std.testing.expectEqual('0', r0[1]);

    // 0x99 → '9','9'
    const r9 = encoding.bcdByteToAscii(0x99);
    try std.testing.expectEqual('9', r9[0]);
    try std.testing.expectEqual('9', r9[1]);
}

test "asciiToBcdByte all valid digit pairs" {
    for (0..10) |hi| {
        for (0..10) |lo| {
            const hi_ascii: u8 = @intCast(hi + 0x30);
            const lo_ascii: u8 = @intCast(lo + 0x30);
            const result = try encoding.asciiToBcdByte(hi_ascii, lo_ascii);
            try std.testing.expectEqual(@as(u8, @intCast((hi << 4) | lo)), result);
        }
    }
}

test "asciiToBcdByte invalid characters" {
    // Below '0'
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte('/', '0'));
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte('0', '/'));
    // Above '9'
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte(':', '0'));
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte('0', ':'));
    // Letters
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte('A', '0'));
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte('0', 'Z'));
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcdByte('a', '0'));
}

// ═══════════════════════════════════════════════════════════════════════════
// BCD Bulk Codec (scalar path)
// ═══════════════════════════════════════════════════════════════════════════

test "bcdToAscii / asciiToBcd round-trip various lengths" {
    // Length 1
    {
        const bcd = [_]u8{0x12};
        var ascii: [2]u8 = undefined;
        encoding.bcdToAscii(&bcd, &ascii);
        try std.testing.expectEqualSlices(u8, "12", &ascii);
        var out: [1]u8 = undefined;
        try encoding.asciiToBcd(&ascii, &out);
        try std.testing.expectEqualSlices(u8, &bcd, &out);
    }
    // Length 8
    {
        const bcd = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0x00, 0x99, 0x55 };
        var ascii: [16]u8 = undefined;
        encoding.bcdToAscii(&bcd, &ascii);
        // Verify round-trip
        var out: [8]u8 = undefined;
        try encoding.asciiToBcd(&ascii, &out);
        try std.testing.expectEqualSlices(u8, &bcd, &out);
    }
    // Length 16
    {
        const bcd = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00, 0x12, 0x34, 0x56, 0x78, 0x90, 0x09 };
        var ascii: [32]u8 = undefined;
        encoding.bcdToAscii(&bcd, &ascii);
        var out: [16]u8 = undefined;
        try encoding.asciiToBcd(&ascii, &out);
        try std.testing.expectEqualSlices(u8, &bcd, &out);
    }
}

test "asciiToBcd rejects odd-length input" {
    var out: [2]u8 = undefined;
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcd("123", &out));
}

test "asciiToBcd rejects non-digit in middle" {
    var out: [2]u8 = undefined;
    try std.testing.expectError(error.InvalidBcdDigit, encoding.asciiToBcd("1X34", &out));
}

// ═══════════════════════════════════════════════════════════════════════════
// ASCII Numeric Parsing
// ═══════════════════════════════════════════════════════════════════════════

test "parseAsciiUint various types" {
    // u8
    try std.testing.expectEqual(@as(u8, 0), try encoding.parseAsciiUint(u8, "0"));
    try std.testing.expectEqual(@as(u8, 255), try encoding.parseAsciiUint(u8, "255"));
    try std.testing.expectError(error.Overflow, encoding.parseAsciiUint(u8, "256"));

    // u16
    try std.testing.expectEqual(@as(u16, 0), try encoding.parseAsciiUint(u16, "0"));
    try std.testing.expectEqual(@as(u16, 65535), try encoding.parseAsciiUint(u16, "65535"));
    try std.testing.expectError(error.Overflow, encoding.parseAsciiUint(u16, "65536"));

    // u32
    try std.testing.expectEqual(@as(u32, 1000000), try encoding.parseAsciiUint(u32, "1000000"));
    try std.testing.expectEqual(@as(u32, 999999999), try encoding.parseAsciiUint(u32, "999999999"));

    // u64
    try std.testing.expectEqual(@as(u64, 0), try encoding.parseAsciiUint(u64, "0"));
    try std.testing.expectEqual(@as(u64, 1), try encoding.parseAsciiUint(u64, "1"));
    try std.testing.expectEqual(@as(u64, 123456789), try encoding.parseAsciiUint(u64, "123456789"));
    try std.testing.expectEqual(@as(u64, 9999999999999999999), try encoding.parseAsciiUint(u64, "9999999999999999999"));
}

test "parseAsciiUint zero-padded" {
    try std.testing.expectEqual(@as(u64, 0), try encoding.parseAsciiUint(u64, "000000"));
    try std.testing.expectEqual(@as(u64, 1), try encoding.parseAsciiUint(u64, "000001"));
    try std.testing.expectEqual(@as(u64, 1000), try encoding.parseAsciiUint(u64, "000000001000"));
    try std.testing.expectEqual(@as(u64, 999), try encoding.parseAsciiUint(u64, "000000000999"));
}

test "parseAsciiUint rejects non-digits" {
    try std.testing.expectError(error.InvalidFieldEncoding, encoding.parseAsciiUint(u64, "12A45"));
    try std.testing.expectError(error.InvalidFieldEncoding, encoding.parseAsciiUint(u64, " 123"));
    try std.testing.expectError(error.InvalidFieldEncoding, encoding.parseAsciiUint(u64, "123 "));
    try std.testing.expectError(error.InvalidFieldEncoding, encoding.parseAsciiUint(u64, "-123"));
}

test "parseAsciiUint empty string" {
    try std.testing.expectError(error.InvalidFieldEncoding, encoding.parseAsciiUint(u64, ""));
}

test "parseAsciiUint overflow" {
    // u64 max = 18446744073709551615, try one more
    try std.testing.expectError(error.Overflow, encoding.parseAsciiUint(u64, "18446744073709551616"));
}

// ═══════════════════════════════════════════════════════════════════════════
// writeAsciiUint
// ═══════════════════════════════════════════════════════════════════════════

test "writeAsciiUint various lengths" {
    // 4 digits
    var buf4: [4]u8 = undefined;
    encoding.writeAsciiUint(42, &buf4);
    try std.testing.expectEqualSlices(u8, "0042", &buf4);

    // 6 digits
    var buf6: [6]u8 = undefined;
    encoding.writeAsciiUint(123456, &buf6);
    try std.testing.expectEqualSlices(u8, "123456", &buf6);

    // 12 digits (common for ISO amount fields)
    var buf12: [12]u8 = undefined;
    encoding.writeAsciiUint(1000, &buf12);
    try std.testing.expectEqualSlices(u8, "000000001000", &buf12);

    // Zero
    var buf3: [3]u8 = undefined;
    encoding.writeAsciiUint(0, &buf3);
    try std.testing.expectEqualSlices(u8, "000", &buf3);
}

test "writeAsciiUint then parseAsciiUint round-trip" {
    var buf: [12]u8 = undefined;
    const value: u64 = 999888777;
    encoding.writeAsciiUint(value, &buf);
    const parsed = try encoding.parseAsciiUint(u64, &buf);
    try std.testing.expectEqual(value, parsed);
}

// ═══════════════════════════════════════════════════════════════════════════
// Length Prefix Codec
// ═══════════════════════════════════════════════════════════════════════════

test "parseLengthPrefix 2-digit" {
    const result = try encoding.parseLengthPrefix("16ABC", 2);
    try std.testing.expectEqual(@as(usize, 16), result.len);
    try std.testing.expectEqual(@as(usize, 2), result.consumed);
}

test "parseLengthPrefix 3-digit" {
    const result = try encoding.parseLengthPrefix("015ABCDE", 3);
    try std.testing.expectEqual(@as(usize, 15), result.len);
    try std.testing.expectEqual(@as(usize, 3), result.consumed);
}

test "parseLengthPrefix 4-digit" {
    const result = try encoding.parseLengthPrefix("0123DATA", 4);
    try std.testing.expectEqual(@as(usize, 123), result.len);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "parseLengthPrefix zero" {
    const result = try encoding.parseLengthPrefix("00", 2);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseLengthPrefix buffer too short" {
    try std.testing.expectError(error.BufferTooShort, encoding.parseLengthPrefix("1", 2));
    try std.testing.expectError(error.BufferTooShort, encoding.parseLengthPrefix("01", 3));
}

test "parseLengthPrefix non-digit in prefix" {
    try std.testing.expectError(error.InvalidFieldEncoding, encoding.parseLengthPrefix("1X", 2));
}

// ═══════════════════════════════════════════════════════════════════════════
// Validation (scalar)
// ═══════════════════════════════════════════════════════════════════════════

test "validateAsciiDigitsScalar comprehensive" {
    // Valid
    try std.testing.expect(encoding.validateAsciiDigitsScalar("0"));
    try std.testing.expect(encoding.validateAsciiDigitsScalar("9"));
    try std.testing.expect(encoding.validateAsciiDigitsScalar("0123456789"));
    try std.testing.expect(encoding.validateAsciiDigitsScalar(""));

    // Invalid — boundary chars
    try std.testing.expect(!encoding.validateAsciiDigitsScalar("/")); // 0x2F, just below '0'
    try std.testing.expect(!encoding.validateAsciiDigitsScalar(":")); // 0x3A, just above '9'

    // Invalid — various non-digits
    try std.testing.expect(!encoding.validateAsciiDigitsScalar(" "));
    try std.testing.expect(!encoding.validateAsciiDigitsScalar("A"));
    try std.testing.expect(!encoding.validateAsciiDigitsScalar("-"));
    try std.testing.expect(!encoding.validateAsciiDigitsScalar("."));
}

test "validateAsciiAlnumScalar comprehensive" {
    // Valid
    try std.testing.expect(encoding.validateAsciiAlnumScalar("A"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar("Z"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar("a"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar("z"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar("0"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar("9"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar("ABC123def456"));
    try std.testing.expect(encoding.validateAsciiAlnumScalar(""));

    // Invalid
    try std.testing.expect(!encoding.validateAsciiAlnumScalar(" "));  // space
    try std.testing.expect(!encoding.validateAsciiAlnumScalar("!"));  // punctuation
    try std.testing.expect(!encoding.validateAsciiAlnumScalar("@"));
    try std.testing.expect(!encoding.validateAsciiAlnumScalar("A B")); // space in middle
}

// ═══════════════════════════════════════════════════════════════════════════
// FieldEncoding enum methods
// ═══════════════════════════════════════════════════════════════════════════

test "FieldEncoding.isAscii" {
    try std.testing.expect(encoding.FieldEncoding.ascii_numeric.isAscii());
    try std.testing.expect(encoding.FieldEncoding.ascii_alpha.isAscii());
    try std.testing.expect(encoding.FieldEncoding.ascii_binary.isAscii());
    try std.testing.expect(!encoding.FieldEncoding.bcd.isAscii());
    try std.testing.expect(!encoding.FieldEncoding.binary.isAscii());
}

test "FieldEncoding.isBcd" {
    try std.testing.expect(encoding.FieldEncoding.bcd.isBcd());
    try std.testing.expect(!encoding.FieldEncoding.ascii_numeric.isBcd());
    try std.testing.expect(!encoding.FieldEncoding.binary.isBcd());
}

// ═══════════════════════════════════════════════════════════════════════════
// LengthType enum methods
// ═══════════════════════════════════════════════════════════════════════════

test "LengthType.fixedLen all fixed types" {
    try std.testing.expectEqual(@as(?usize, 1), encoding.LengthType.fixed_1.fixedLen());
    try std.testing.expectEqual(@as(?usize, 2), encoding.LengthType.fixed_2.fixedLen());
    try std.testing.expectEqual(@as(?usize, 3), encoding.LengthType.fixed_3.fixedLen());
    try std.testing.expectEqual(@as(?usize, 4), encoding.LengthType.fixed_4.fixedLen());
    try std.testing.expectEqual(@as(?usize, 6), encoding.LengthType.fixed_6.fixedLen());
    try std.testing.expectEqual(@as(?usize, 8), encoding.LengthType.fixed_8.fixedLen());
    try std.testing.expectEqual(@as(?usize, 10), encoding.LengthType.fixed_10.fixedLen());
    try std.testing.expectEqual(@as(?usize, 12), encoding.LengthType.fixed_12.fixedLen());
    try std.testing.expectEqual(@as(?usize, 15), encoding.LengthType.fixed_15.fixedLen());
    try std.testing.expectEqual(@as(?usize, 16), encoding.LengthType.fixed_16.fixedLen());
    try std.testing.expectEqual(@as(?usize, 32), encoding.LengthType.fixed_32.fixedLen());
    try std.testing.expectEqual(@as(?usize, 41), encoding.LengthType.fixed_41.fixedLen());
    try std.testing.expectEqual(@as(?usize, 42), encoding.LengthType.fixed_42.fixedLen());
    try std.testing.expectEqual(@as(?usize, 52), encoding.LengthType.fixed_52.fixedLen());
    try std.testing.expectEqual(@as(?usize, 64), encoding.LengthType.fixed_64.fixedLen());
    try std.testing.expectEqual(@as(?usize, 128), encoding.LengthType.fixed_128.fixedLen());
}

test "LengthType.fixedLen variable types return null" {
    try std.testing.expectEqual(@as(?usize, null), encoding.LengthType.llvar.fixedLen());
    try std.testing.expectEqual(@as(?usize, null), encoding.LengthType.lllvar.fixedLen());
    try std.testing.expectEqual(@as(?usize, null), encoding.LengthType.llllvar.fixedLen());
}

test "LengthType.prefixDigits" {
    try std.testing.expectEqual(@as(?u3, null), encoding.LengthType.fixed_6.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 2), encoding.LengthType.llvar.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 3), encoding.LengthType.lllvar.prefixDigits());
    try std.testing.expectEqual(@as(?u3, 4), encoding.LengthType.llllvar.prefixDigits());
}

test "LengthType.isVariable" {
    try std.testing.expect(!encoding.LengthType.fixed_6.isVariable());
    try std.testing.expect(!encoding.LengthType.fixed_12.isVariable());
    try std.testing.expect(encoding.LengthType.llvar.isVariable());
    try std.testing.expect(encoding.LengthType.lllvar.isVariable());
    try std.testing.expect(encoding.LengthType.llllvar.isVariable());
}
