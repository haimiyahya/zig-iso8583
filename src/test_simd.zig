//! Comprehensive tests for the SIMD module.
//! Covers validation, BCD conversion, bitmap ops, memchr, boundary conditions.

const std = @import("std");
const simd = @import("simd.zig");

// ═══════════════════════════════════════════════════════════════════════════
// validateAsciiDigits
// ═══════════════════════════════════════════════════════════════════════════

test "validateAsciiDigits empty" {
    try std.testing.expect(simd.validateAsciiDigits(""));
}

test "validateAsciiDigits single char" {
    try std.testing.expect(simd.validateAsciiDigits("0"));
    try std.testing.expect(simd.validateAsciiDigits("9"));
    try std.testing.expect(!simd.validateAsciiDigits("A"));
    try std.testing.expect(!simd.validateAsciiDigits("/"));
    try std.testing.expect(!simd.validateAsciiDigits(":"));
}

test "validateAsciiDigits short strings (< SIMD_WIDTH)" {
    try std.testing.expect(simd.validateAsciiDigits("1"));
    try std.testing.expect(simd.validateAsciiDigits("12"));
    try std.testing.expect(simd.validateAsciiDigits("123"));
    try std.testing.expect(simd.validateAsciiDigits("1234567890"));
    try std.testing.expect(simd.validateAsciiDigits("012345"));
    try std.testing.expect(!simd.validateAsciiDigits("1234X678"));
}

test "validateAsciiDigits exactly SIMD_WIDTH (16 bytes)" {
    try std.testing.expect(simd.validateAsciiDigits("0123456789012345"));
    try std.testing.expect(!simd.validateAsciiDigits("012345678901234X"));
}

test "validateAsciiDigits multiple of SIMD_WIDTH" {
    // 32 bytes
    try std.testing.expect(simd.validateAsciiDigits("01234567890123450123456789012345"));
    // 48 bytes
    try std.testing.expect(simd.validateAsciiDigits("012345678901234501234567890123450123456789012345"));
}

test "validateAsciiDigits large with invalid at various positions" {
    var buf: [64]u8 = undefined;
    for (0..64) |i| buf[i] = @intCast((i % 10) + 0x30);
    // All valid
    try std.testing.expect(simd.validateAsciiDigits(&buf));

    // Invalid at position 0
    buf[0] = 'X';
    try std.testing.expect(!simd.validateAsciiDigits(&buf));
    buf[0] = '0';

    // Invalid at position 15 (end of first SIMD chunk)
    buf[15] = 'X';
    try std.testing.expect(!simd.validateAsciiDigits(&buf));
    buf[15] = '0';

    // Invalid at position 16 (start of second SIMD chunk)
    buf[16] = 'X';
    try std.testing.expect(!simd.validateAsciiDigits(&buf));
    buf[16] = '0';

    // Invalid at position 63 (last byte, scalar tail)
    buf[63] = 'X';
    try std.testing.expect(!simd.validateAsciiDigits(&buf));
}

test "validateAsciiDigits boundary chars" {
    // '/' = 0x2F (just below '0')
    try std.testing.expect(!simd.validateAsciiDigits("/"));
    // ':' = 0x3A (just above '9')
    try std.testing.expect(!simd.validateAsciiDigits(":"));
}

// ═══════════════════════════════════════════════════════════════════════════
// validateAsciiDigitsWide
// ═══════════════════════════════════════════════════════════════════════════

test "validateAsciiDigitsWide short falls back to 16-byte path" {
    try std.testing.expect(simd.validateAsciiDigitsWide("12345"));
    try std.testing.expect(!simd.validateAsciiDigitsWide("12X45"));
}

test "validateAsciiDigitsWide 32+ bytes" {
    // This contains letters — not valid digits!
    // Let me use only digits
    const digits32 = "01234567890123450123456789012345";
    try std.testing.expect(simd.validateAsciiDigitsWide(digits32));
}

// ═══════════════════════════════════════════════════════════════════════════
// validateAsciiAlnum
// ═══════════════════════════════════════════════════════════════════════════

test "validateAsciiAlnum various" {
    try std.testing.expect(simd.validateAsciiAlnum(""));
    try std.testing.expect(simd.validateAsciiAlnum("A"));
    try std.testing.expect(simd.validateAsciiAlnum("Z"));
    try std.testing.expect(simd.validateAsciiAlnum("a"));
    try std.testing.expect(simd.validateAsciiAlnum("z"));
    try std.testing.expect(simd.validateAsciiAlnum("0"));
    try std.testing.expect(simd.validateAsciiAlnum("9"));
    try std.testing.expect(simd.validateAsciiAlnum("ABC123def456XYZ"));
}

test "validateAsciiAlnum rejects special chars" {
    try std.testing.expect(!simd.validateAsciiAlnum(" "));
    try std.testing.expect(!simd.validateAsciiAlnum("!"));
    try std.testing.expect(!simd.validateAsciiAlnum("@"));
    try std.testing.expect(!simd.validateAsciiAlnum("#"));
    try std.testing.expect(!simd.validateAsciiAlnum("A B"));
}

test "validateAsciiAlnum exactly 16 bytes" {
    try std.testing.expect(simd.validateAsciiAlnum("ABC123def456XYZ7"));
    try std.testing.expect(!simd.validateAsciiAlnum("ABC123def456XYZ "));
}

test "validateAsciiAlnum large" {
    var buf: [64]u8 = undefined;
    for (0..64) |i| buf[i] = if (i % 2 == 0) @intCast((i % 10) + 0x30) else @intCast((i % 26) + 0x41);
    try std.testing.expect(simd.validateAsciiAlnum(&buf));
    buf[32] = ' ';
    try std.testing.expect(!simd.validateAsciiAlnum(&buf));
}

// ═══════════════════════════════════════════════════════════════════════════
// bcdToAscii / asciiToBcd
// ═══════════════════════════════════════════════════════════════════════════

test "bcdToAscii single byte" {
    const bcd = [_]u8{0x12};
    var out: [2]u8 = undefined;
    simd.bcdToAscii(&bcd, &out);
    try std.testing.expectEqualSlices(u8, "12", &out);
}

test "bcdToAscii multiple of 16 (SIMD path)" {
    var bcd: [16]u8 = undefined;
    for (0..16) |i| bcd[i] = @intCast(i * 17); // 0x00, 0x11, 0x22, ..., 0xFF
    // But only 0x00-0x99 are valid BCD. Let's use valid ones:
    for (0..16) |i| bcd[i] = @intCast((i % 10) * 0x11); // 0x00,0x11,...,0x99,0x00,...
    var out: [32]u8 = undefined;
    simd.bcdToAscii(&bcd, &out);
    // Verify first pair: bcd[0]=0x00 → "00"
    try std.testing.expectEqual('0', out[0]);
    try std.testing.expectEqual('0', out[1]);
    // Verify round-trip
    var bcd_out: [16]u8 = undefined;
    try simd.asciiToBcd(&out, &bcd_out);
    try std.testing.expectEqualSlices(u8, &bcd, &bcd_out);
}

test "bcdToAscii/asciiToBcd round-trip various lengths" {
    // Lengths: 1, 3, 7, 8, 15, 16, 17, 32
    const lengths = [_]usize{ 1, 3, 7, 8, 15, 16, 17, 32 };
    for (&lengths) |len| {
        var bcd: [32]u8 = undefined;
        for (0..len) |i| {
            const hi: u8 = @intCast((i * 3 + 1) % 10);
            const lo: u8 = @intCast((i * 7 + 2) % 10);
            bcd[i] = (hi << 4) | lo;
        }
        var ascii: [64]u8 = undefined;
        simd.bcdToAscii(bcd[0..len], ascii[0 .. len * 2]);

        var bcd_out: [32]u8 = undefined;
        try simd.asciiToBcd(ascii[0 .. len * 2], bcd_out[0..len]);
        try std.testing.expectEqualSlices(u8, bcd[0..len], bcd_out[0..len]);
    }
}

test "asciiToBcd rejects non-digit" {
    var out: [2]u8 = undefined;
    try std.testing.expectError(error.InvalidBcdDigit, simd.asciiToBcd("1X", &out));
    try std.testing.expectError(error.InvalidBcdDigit, simd.asciiToBcd("X1", &out));
}

// ═══════════════════════════════════════════════════════════════════════════
// Bitmap operations
// ═══════════════════════════════════════════════════════════════════════════

test "decodeBitmapPresence empty" {
    const bitmap = [_]u8{0} ** 16;
    const present = simd.decodeBitmapPresence(&bitmap);
    for (0..128) |i| {
        try std.testing.expect(!present[i]);
    }
}

test "decodeBitmapPresence single bits" {
    // Set each bit individually and verify
    for (0..128) |target_bit| {
        var bitmap: [16]u8 = .{0} ** 16;
        const byte_idx = target_bit / 8;
        const bit_in_byte: u3 = @intCast(7 - (target_bit % 8));
        bitmap[byte_idx] |= @as(u8, 1) << bit_in_byte;

        const present = simd.decodeBitmapPresence(&bitmap);
        try std.testing.expect(present[target_bit]);
        // All others should be false
        for (0..128) |i| {
            if (i != target_bit) {
                try std.testing.expect(!present[i]);
            }
        }
    }
}

test "countPresentFields" {
    var bitmap: [16]u8 = .{0} ** 16;
    try std.testing.expectEqual(@as(u32, 0), simd.countPresentFields(&bitmap));

    // Set 1 bit
    bitmap[0] = 0x80;
    try std.testing.expectEqual(@as(u32, 1), simd.countPresentFields(&bitmap));

    // Set all bits
    for (0..16) |i| bitmap[i] = 0xFF;
    try std.testing.expectEqual(@as(u32, 128), simd.countPresentFields(&bitmap));
}

test "hasSecondaryBitmap" {
    var primary: [8]u8 = .{0} ** 8;
    try std.testing.expect(!simd.hasSecondaryBitmap(&primary));

    primary[0] = 0x80; // bit 1 set
    try std.testing.expect(simd.hasSecondaryBitmap(&primary));

    primary[0] = 0x40; // bit 2 set, bit 1 clear
    try std.testing.expect(!simd.hasSecondaryBitmap(&primary));
}

// ═══════════════════════════════════════════════════════════════════════════
// memChr
// ═══════════════════════════════════════════════════════════════════════════

test "memChr found at start" {
    try std.testing.expectEqual(@as(?usize, 0), simd.memChr("abc", 'a'));
}

test "memChr found at end" {
    try std.testing.expectEqual(@as(?usize, 2), simd.memChr("abc", 'c'));
}

test "memChr not found" {
    try std.testing.expectEqual(@as(?usize, null), simd.memChr("abc", 'z'));
}

test "memChr empty" {
    try std.testing.expectEqual(@as(?usize, null), simd.memChr("", 'a'));
}

test "memChr single char" {
    try std.testing.expectEqual(@as(?usize, 0), simd.memChr("x", 'x'));
    try std.testing.expectEqual(@as(?usize, null), simd.memChr("x", 'y'));
}

test "memChr first occurrence" {
    try std.testing.expectEqual(@as(?usize, 0), simd.memChr("xxyy", 'x'));
}

test "memChr in long string (crosses SIMD boundary)" {
    // 32+ bytes
    const haystack = "aaaaaaaaaaaaaaaXaaaaaaaaaaaaaaaY";
    try std.testing.expectEqual(@as(?usize, 15), simd.memChr(haystack, 'X'));
    try std.testing.expectEqual(@as(?usize, 31), simd.memChr(haystack, 'Y'));
    try std.testing.expectEqual(@as(?usize, null), simd.memChr(haystack, 'Z'));
}

// ═══════════════════════════════════════════════════════════════════════════
// Scalar fallback functions
// ═══════════════════════════════════════════════════════════════════════════

test "validateAsciiDigitsScalar" {
    try std.testing.expect(simd.validateAsciiDigitsScalar("12345"));
    try std.testing.expect(!simd.validateAsciiDigitsScalar("123A5"));
    try std.testing.expect(simd.validateAsciiDigitsScalar(""));
}

test "validateAsciiAlnumScalar" {
    try std.testing.expect(simd.validateAsciiAlnumScalar("ABC123"));
    try std.testing.expect(!simd.validateAsciiAlnumScalar("ABC 123"));
    try std.testing.expect(simd.validateAsciiAlnumScalar(""));
}

test "bcdToAsciiScalar" {
    const bcd = [_]u8{ 0x12, 0x34 };
    var out: [4]u8 = undefined;
    simd.bcdToAsciiScalar(&bcd, &out);
    try std.testing.expectEqualSlices(u8, "1234", &out);
}

test "asciiToBcdScalar" {
    var out: [2]u8 = undefined;
    try simd.asciiToBcdScalar("1234", &out);
    try std.testing.expectEqual(@as(u8, 0x12), out[0]);
    try std.testing.expectEqual(@as(u8, 0x34), out[1]);
}

// ═══════════════════════════════════════════════════════════════════════════
// SIMD vs Scalar consistency
// ═══════════════════════════════════════════════════════════════════════════

test "SIMD validateAsciiDigits matches scalar for various inputs" {
    const inputs = [_][]const u8{
        "12345",
        "0123456789",
        "0000000000000000",
        "9999999999999999",
        "1234X678",
        "",
        "0",
    };
    for (&inputs) |input| {
        const simd_result = simd.validateAsciiDigits(input);
        const scalar_result = simd.validateAsciiDigitsScalar(input);
        try std.testing.expectEqual(scalar_result, simd_result);
    }
}

test "SIMD validateAsciiAlnum matches scalar for various inputs" {
    const inputs = [_][]const u8{
        "ABC123",
        "ABC 123",
        "",
        "A",
        "0123456789ABCDEF",
    };
    for (&inputs) |input| {
        const simd_result = simd.validateAsciiAlnum(input);
        const scalar_result = simd.validateAsciiAlnumScalar(input);
        try std.testing.expectEqual(scalar_result, simd_result);
    }
}

test "SIMD bcdToAscii matches scalar" {
    const bcd = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0x00, 0x99, 0x55,
                        0x01, 0x23, 0x45, 0x67, 0x89, 0x33, 0x77, 0x88 };
    var simd_out: [32]u8 = undefined;
    var scalar_out: [32]u8 = undefined;
    simd.bcdToAscii(&bcd, &simd_out);
    simd.bcdToAsciiScalar(&bcd, &scalar_out);
    try std.testing.expectEqualSlices(u8, &scalar_out, &simd_out);
}
