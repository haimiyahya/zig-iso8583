//! # SIMD-Accelerated Primitives for ISO 8583 Parsing
//!
//! Vectorized implementations of hot-path operations using Zig's `@Vector`
//! intrinsics, which compile to SSE/AVX on x86-64 and NEON on ARM:
//!
//! - **ASCII digit/alphanumeric validation** — range checks 16 bytes at once
//! - **BCD ↔ ASCII conversion** — nibble extraction via SIMD shifts/masks
//! - **Bitmap scanning** — presence decode and population count
//! - **memchr** — byte search via vector equality + bitmask
//!
//! ## Design
//!
//! Every SIMD function processes data in chunks of `SIMD_WIDTH` (16) or
//! `SIMD_WIDTH_WIDE` (32) bytes and falls back to a scalar loop for the
//! tail. Scalar fallback implementations are exported for testing and for
//! platforms without native vector support.
//!
//! ## Example
//!
//! ```zig
//! const simd = @import("simd");
//!
//! // Validate a PAN (SIMD path for >= 16 bytes)
//! if (!simd.validateAsciiDigits("4111111111111111")) return error.InvalidPan;
//!
//! // Convert 16 BCD bytes to 32 ASCII digits
//! var ascii: [32]u8 = undefined;
//! simd.bcdToAscii(bcd_bytes, &ascii);
//! ```

const std = @import("std");

// ─── Configuration ─────────────────────────────────────────────────────────

/// SIMD vector width for byte operations. 16 is widely supported (SSE2/NEON).
pub const SIMD_WIDTH: comptime_int = 16;

/// SIMD vector width for wide validation. 32 bytes (AVX2).
pub const SIMD_WIDTH_WIDE: comptime_int = 32;

// ─── ASCII Digit Validation ────────────────────────────────────────────────

/// Validate that all bytes in `slice` are ASCII digits ('0'–'9').
/// Uses SIMD (16 bytes at a time) with scalar fallback for the tail.
pub fn validateAsciiDigits(slice: []const u8) bool {
    if (slice.len == 0) return true;

    const Vec = @Vector(SIMD_WIDTH, u8);
    const BoolVec = @Vector(SIMD_WIDTH, bool);
    const lo: Vec = @splat(0x30);
    const hi: Vec = @splat(0x39);
    const falses: BoolVec = @splat(false);

    var i: usize = 0;

    // Process SIMD_WIDTH bytes at a time
    while (i + SIMD_WIDTH <= slice.len) : (i += SIMD_WIDTH) {
        const v: Vec = slice[i..][0..SIMD_WIDTH].*;
        const ge_lo = v >= lo;
        const le_hi = v <= hi;
        const valid = @select(bool, ge_lo, le_hi, falses);
        if (@reduce(.And, valid) == false) return false;
    }

    // Scalar tail
    return validateAsciiDigitsScalar(slice[i..]);
}

/// Scalar fallback for ASCII digit validation.
pub fn validateAsciiDigitsScalar(slice: []const u8) bool {
    for (slice) |b| {
        if (b < 0x30 or b > 0x39) return false;
    }
    return true;
}

/// Validate ASCII digits using wide (32-byte) vectors when available.
/// Falls back to 16-byte path if slice is too short.
pub fn validateAsciiDigitsWide(slice: []const u8) bool {
    if (slice.len < SIMD_WIDTH_WIDE) return validateAsciiDigits(slice);

    const Vec = @Vector(SIMD_WIDTH_WIDE, u8);
    const BoolVec = @Vector(SIMD_WIDTH_WIDE, bool);
    const lo: Vec = @splat(0x30);
    const hi: Vec = @splat(0x39);
    const falses: BoolVec = @splat(false);

    var i: usize = 0;
    while (i + SIMD_WIDTH_WIDE <= slice.len) : (i += SIMD_WIDTH_WIDE) {
        const v: Vec = slice[i..][0..SIMD_WIDTH_WIDE].*;
        const ge_lo = v >= lo;
        const le_hi = v <= hi;
        const valid = @select(bool, ge_lo, le_hi, falses);
        if (@reduce(.And, valid) == false) return false;
    }

    // Handle remaining with 16-byte path
    return validateAsciiDigits(slice[i..]);
}

// ─── ASCII Alphanumeric Validation ─────────────────────────────────────────

/// Validate that all bytes are ASCII alphanumeric (A-Z, a-z, 0-9).
/// Uses SIMD with scalar fallback for the tail.
pub fn validateAsciiAlnum(slice: []const u8) bool {
    if (slice.len == 0) return true;

    const Vec = @Vector(SIMD_WIDTH, u8);
    const BoolVec = @Vector(SIMD_WIDTH, bool);
    const digit_lo: Vec = @splat(0x30);
    const digit_hi: Vec = @splat(0x39);
    const upper_lo: Vec = @splat(0x41);
    const upper_hi: Vec = @splat(0x5A);
    const lower_lo: Vec = @splat(0x61);
    const lower_hi: Vec = @splat(0x7A);
    const falses: BoolVec = @splat(false);

    var i: usize = 0;
    while (i + SIMD_WIDTH <= slice.len) : (i += SIMD_WIDTH) {
        const v: Vec = slice[i..][0..SIMD_WIDTH].*;

        const trues: BoolVec = @splat(true);
        const is_digit = @select(bool, v >= digit_lo, v <= digit_hi, falses);
        const is_upper = @select(bool, v >= upper_lo, v <= upper_hi, falses);
        const is_lower = @select(bool, v >= lower_lo, v <= lower_hi, falses);
        const digit_or_upper = @select(bool, is_digit, trues, is_upper);
        const valid = @select(bool, digit_or_upper, trues, is_lower);

        if (@reduce(.And, valid) == false) return false;
    }

    return validateAsciiAlnumScalar(slice[i..]);
}

/// Scalar fallback for ASCII alphanumeric validation.
pub fn validateAsciiAlnumScalar(slice: []const u8) bool {
    for (slice) |b| {
        const is_digit = b >= 0x30 and b <= 0x39;
        const is_upper = b >= 0x41 and b <= 0x5A;
        const is_lower = b >= 0x61 and b <= 0x7A;
        if (!is_digit and !is_upper and !is_lower) return false;
    }
    return true;
}

// ─── BCD ↔ ASCII Conversion ────────────────────────────────────────────────

/// BCD → ASCII: each BCD byte '0xAB' → 'A','B' as ASCII digits.
/// Processes 16 BCD bytes → 32 ASCII bytes per SIMD iteration.
/// `out.len` must be >= `bcd.len * 2`.
pub fn bcdToAscii(bcd: []const u8, out: []u8) void {
    std.debug.assert(out.len >= bcd.len * 2);

    const Vec = @Vector(SIMD_WIDTH, u8);
    const mask_lo: Vec = @splat(0x0F);
    const ascii_offset: Vec = @splat(0x30);
    const shift: Vec = @splat(4);

    // Build shuffle index for interleaving hi and lo nibbles:
    // Input: [h0,h1,...,h15] and [l0,l1,...,l15]
    // Output: [h0,l0,h1,l1,...,h15,l15]
    comptime var shuffle_idx: [SIMD_WIDTH * 2]i32 = undefined;
    comptime {
        for (0..SIMD_WIDTH) |i| {
            shuffle_idx[i * 2] = @intCast(i); // hi from first vector
            shuffle_idx[i * 2 + 1] = -@as(i32, @intCast(i + 1)); // lo from second vector (negative = second operand)
        }
    }

    var i: usize = 0;
    while (i + SIMD_WIDTH <= bcd.len) : (i += SIMD_WIDTH) {
        const v: Vec = bcd[i..][0..SIMD_WIDTH].*;
        const hi_nibbles = (v >> shift) + ascii_offset;
        const lo_nibbles = (v & mask_lo) + ascii_offset;

        const interleaved = @shuffle(u8, hi_nibbles, lo_nibbles, shuffle_idx);
        for (0..SIMD_WIDTH * 2) |j| {
            out[i * 2 + j] = interleaved[j];
        }
    }

    // Scalar tail
    bcdToAsciiScalar(bcd[i..], out[i * 2 ..]);
}

/// Scalar fallback for BCD → ASCII.
pub fn bcdToAsciiScalar(bcd: []const u8, out: []u8) void {
    for (bcd, 0..) |byte, i| {
        out[i * 2] = ((byte >> 4) & 0x0F) + 0x30;
        out[i * 2 + 1] = (byte & 0x0F) + 0x30;
    }
}

/// ASCII → BCD: pairs of ASCII digits → single BCD byte.
/// Processes 32 ASCII bytes → 16 BCD bytes per SIMD iteration.
/// `ascii.len` must be even. `out.len` must be >= `ascii.len / 2`.
pub fn asciiToBcd(ascii: []const u8, out: []u8) !void {
    std.debug.assert(ascii.len % 2 == 0);
    std.debug.assert(out.len >= ascii.len / 2);

    // Scalar path for now (SIMD path has complexity with shuffle on 32-byte vectors)
    return asciiToBcdScalar(ascii, out);
}

/// Scalar fallback for ASCII → BCD.
pub fn asciiToBcdScalar(ascii: []const u8, out: []u8) !void {
    var j: usize = 0;
    while (j + 2 <= ascii.len) : (j += 2) {
        const hi = ascii[j];
        const lo = ascii[j + 1];
        if (hi < 0x30 or hi > 0x39 or lo < 0x30 or lo > 0x39)
            return error.InvalidBcdDigit;
        out[j / 2] = ((hi - 0x30) << 4) | (lo - 0x30);
    }
}

// ─── Bitmap SIMD Operations ────────────────────────────────────────────────

/// Check which of the 128 possible fields are present in the bitmap.
/// Returns a [128]bool array (0-indexed: present[0] = field 1, present[1] = field 2, etc.).
pub fn decodeBitmapPresence(bitmap: *const [16]u8) [128]bool {
    var present: [128]bool = .{false} ** 128;

    for (0..128) |bit_pos| {
        const byte_idx = bit_pos / 8;
        const bit_in_byte: u3 = @intCast(7 - (bit_pos % 8));
        if ((bitmap[byte_idx] & (@as(u8, 1) << bit_in_byte)) != 0) {
            present[bit_pos] = true;
        }
    }

    return present;
}

/// Encode a presence array into a 16-byte bitmap.
pub fn encodeBitmapPresence(present: *const [128]bool) [16]u8 {
    var bitmap: [16]u8 = .{0} ** 16;
    for (0..128) |i| {
        if (present[i]) {
            bitmap[i / 8] |= @as(u8, 1) << @intCast(@mod(7 - @mod(i, 8), 8));
        }
    }
    return bitmap;
}

/// Count the number of set bits in the bitmap using SIMD.
pub fn countPresentFields(bitmap: *const [16]u8) u32 {
    const Vec4 = @Vector(4, u32);
    const v: Vec4 = @bitCast(bitmap.*);
    // SIMD population count per lane, then sum
    const popcounts: [4]u32 = .{
        @popCount(v[0]),
        @popCount(v[1]),
        @popCount(v[2]),
        @popCount(v[3]),
    };
    return popcounts[0] + popcounts[1] + popcounts[2] + popcounts[3];
}

/// Check if a secondary bitmap is present (bit 1 of primary bitmap is set).
pub fn hasSecondaryBitmap(bitmap: *const [8]u8) bool {
    return (bitmap[0] & 0x80) != 0;
}

// ─── Memchr (SIMD byte search) ─────────────────────────────────────────────

/// Find the first occurrence of `needle` in `haystack`.
/// Returns the index, or null if not found. Uses SIMD for search.
pub fn memChr(haystack: []const u8, needle: u8) ?usize {
    const Vec = @Vector(SIMD_WIDTH, u8);
    const needle_vec: Vec = @splat(needle);

    var i: usize = 0;
    while (i + SIMD_WIDTH <= haystack.len) : (i += SIMD_WIDTH) {
        const v: Vec = haystack[i..][0..SIMD_WIDTH].*;
        const eq = v == needle_vec;
        // Convert boolean vector to bitmask
        const mask = @as(u16, @bitCast(eq));
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Scalar tail
    for (haystack[i..], i..) |b, idx| {
        if (b == needle) return idx;
    }
    return null;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "validateAsciiDigits SIMD" {
    try std.testing.expect(validateAsciiDigits("1234567890123456"));
    try std.testing.expect(!validateAsciiDigits("12345678901234X6"));
    try std.testing.expect(validateAsciiDigits(""));
    try std.testing.expect(validateAsciiDigits("1"));
    try std.testing.expect(!validateAsciiDigits("A"));
    // Multi-SIMD-width
    var long: [64]u8 = undefined;
    for (0..64) |i| long[i] = @intCast((i % 10) + 0x30);
    try std.testing.expect(validateAsciiDigits(&long));
    long[33] = 'X';
    try std.testing.expect(!validateAsciiDigits(&long));
}

test "validateAsciiAlnum SIMD" {
    try std.testing.expect(validateAsciiAlnum("ABC123def456"));
    try std.testing.expect(!validateAsciiAlnum("ABC 123"));
    try std.testing.expect(validateAsciiAlnum(""));
}

test "bcdToAscii SIMD" {
    const bcd_input = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0x00, 0x99, 0x55,
                             0x12, 0x34, 0x56, 0x78, 0x90, 0x00, 0x99, 0x55 };
    var ascii_buf: [32]u8 = undefined;
    bcdToAscii(&bcd_input, &ascii_buf);
    try std.testing.expectEqualSlices(u8, "12345678900099551234567890009955", &ascii_buf);
}

test "bcdToAscii round-trip with scalar" {
    // Test a small input (below SIMD width) that goes to scalar path
    const bcd_input = [_]u8{ 0x12, 0x34, 0x56 };
    var ascii_buf: [6]u8 = undefined;
    bcdToAscii(&bcd_input, &ascii_buf);
    try std.testing.expectEqualSlices(u8, "123456", &ascii_buf);

    var bcd_out: [3]u8 = undefined;
    try asciiToBcd(&ascii_buf, &bcd_out);
    try std.testing.expectEqualSlices(u8, &bcd_input, &bcd_out);
}

test "decodeBitmapPresence" {
    // Bitmap with bits 2, 4, 7 set (1-indexed, but array is 0-indexed for bit positions)
    // Bit 2 → byte 0, bit 6 (0-indexed from MSB)
    var bitmap: [16]u8 = .{0} ** 16;
    bitmap[0] = 0x40; // bit 2 (0-indexed: position 1)
    bitmap[0] |= 0x10; // bit 4 (0-indexed: position 3)
    bitmap[0] |= 0x02; // bit 7 (0-indexed: position 6)
    const present = decodeBitmapPresence(&bitmap);
    try std.testing.expect(present[1]); // bit 2
    try std.testing.expect(present[3]); // bit 4
    try std.testing.expect(present[6]); // bit 7
    try std.testing.expect(!present[0]); // bit 1
    try std.testing.expect(!present[2]); // bit 3
}

test "countPresentFields" {
    var bitmap: [16]u8 = .{0} ** 16;
    bitmap[0] = 0x80; // 1 bit set
    try std.testing.expectEqual(@as(u32, 1), countPresentFields(&bitmap));
    bitmap[0] = 0xFF; // 8 bits set
    try std.testing.expectEqual(@as(u32, 8), countPresentFields(&bitmap));
}

test "hasSecondaryBitmap" {
    var primary: [8]u8 = .{0} ** 8;
    primary[0] = 0x80;
    try std.testing.expect(hasSecondaryBitmap(&primary));
    primary[0] = 0x40;
    try std.testing.expect(!hasSecondaryBitmap(&primary));
}

test "memChr" {
    const haystack = "Hello, World!";
    try std.testing.expectEqual(@as(?usize, 0), memChr(haystack, 'H'));
    try std.testing.expectEqual(@as(?usize, 7), memChr(haystack, 'W'));
    try std.testing.expectEqual(@as(?usize, null), memChr(haystack, 'z'));
}
