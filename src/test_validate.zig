//! Comprehensive tests for# the validate module.
//! Covers all encoding validations, SIMD hex, required fields rules.

const std = @import("std");
const validate = @import("validate.zig");
const encoding = @import("encoding.zig");

// ═══════════════════════════════════════════════════════════════════════════
// validateFieldData — ascii_numeric
// ═══════════════════════════════════════════════════════════════════════════

test "validateFieldData ascii_numeric valid" {
    try validate.validateFieldData("0", .ascii_numeric);
    try validate.validateFieldData("9", .ascii_numeric);
    try validate.validateFieldData("0123456789", .ascii_numeric);
    try validate.validateFieldData("000000001000", .ascii_numeric);
    try validate.validateFieldData("999999999999", .ascii_numeric);
}

test "validateFieldData ascii_numeric invalid" {
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData("123A56", .ascii_numeric));
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData(" 1234", .ascii_numeric));
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData("1234 ", .ascii_numeric));
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData("-1234", .ascii_numeric));
}

// ═══════════════════════════════════════════════════════════════════════════
// validateFieldData — ascii_alpha
// ═══════════════════════════════════════════════════════════════════════════

test "validateFieldData ascii_alpha valid" {
    try validate.validateFieldData("A", .ascii_alpha);
    try validate.validateFieldData("Z", .ascii_alpha);
    try validate.validateFieldData("a", .ascii_alpha);
    try validate.validateFieldData("z", .ascii_alpha);
    try validate.validateFieldData("0", .ascii_alpha);
    try validate.validateFieldData("ABC123EFG123", .ascii_alpha);
    try validate.validateFieldData("TERM001", .ascii_alpha);
}

test "validateFieldData ascii_alpha invalid" {
    try std.testing.expectError(error.InvalidAlnum, validate.validateFieldData("A B", .ascii_alpha));
    try std.testing.expectError(error.InvalidAlnum, validate.validateFieldData("!ABC", .ascii_alpha));
    try std.testing.expectError(error.InvalidAlnum, validate.validateFieldData("ABC!", .ascii_alpha));
}

// ═══════════════════════════════════════════════════════════════════════════
// validateFieldData — ascii_binary (hex)
// ═══════════════════════════════════════════════════════════════════════════

test "validateFieldData ascii_binary valid" {
    try validate.validateFieldData("0123456789ABCDEF", .ascii_binary);
    try validate.validateFieldData("0123456789abcdef", .ascii_binary);
    try validate.validateFieldData("A0B1C2", .ascii_binary);
    try validate.validateFieldData("0", .ascii_binary);
}

test "validateFieldData ascii_binary invalid" {
    try std.testing.expectError(error.InvalidAlnum, validate.validateFieldData("G", .ascii_binary));
    try std.testing.expectError(error.InvalidAlnum, validate.validateFieldData("ABCDG", .ascii_binary));
}

// ═════════════════════════════════════════════════════════D════════════════
// validateFieldData — bcd
// ═══════════════════════════════════════════════════════════════════════════

test "validateFieldData bcd valid" {
    try validate.validateFieldData(&[_]u8{0x12}, .bcd);
    try validate.validateFieldData(&[_]u8{0x00}, .bcd);
    try validate.validateFieldData(&[_]u8{0x99}, .bcd);
    try validate.validateFieldData(&[_]u8{ 0x12, 0x34, 0x56 }, .bcd);
}

test "validateFieldData bcd invalid — nibble > 9" {
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData(&[_]u8{0xAB}, .bcd));
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData(&[_]u8{0x1A}, .bcd));
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData(&[_]u8{0xA1}, .bcd));
    try std.testing.expectError(error.InvalidDigits, validate.validateFieldData(&[_]u8{0xFF}, .bcd));
}

// ═══════════════════════════════════════════════════════════════════════════
// validateFieldData — binary (always valid)
// ═══════════════════════════════════════════════════════════════════════════

test "validateFieldData binary always valid" {
    try validate.validateFieldData(&[_]u8{0x00}, .binary);
    try validate.validateFieldData(&[_]u8{0xFF}, .binary);
    try validate.validateFieldData(&[_]u8{ 0x80, 0x7F, 0xAA, 0x55 }, .binary);
}

// ═══════════════════════════════════════════════════════════════════════════
// validateFieldData — empty
// ═══════════════════════════════════════════════════════════════════════════

test "validateFieldData empty returns error" {
    try std.testing.expectError(error.EmptyField, validate.validateFieldData("", .ascii_numeric));
    try std.testing.expectError(error.EmptyField, validate.validateFieldData("", .ascii_alpha));
    try std.testing.expectError(error.EmptyField, validate.validateFieldData("", .ascii_binary));
    try std.testing.expectError(error.EmptyField, validate.validateFieldData(&[_]u8{}, .bcd));
    try std.testing.expectError(error.EmptyField, validate.validateFieldData(&[_]u8{}, .binary));
}

// ═══════════════════════════════════════════════════════════════════════════
// validateAsciiHex
// ═══════════════════════════════════════════════════════════════════════════

test "validateAsciiHex valid" {
    try std.testing.expect(validate.validateAsciiHex("0123456789ABCDEF"));
    try std.testing.expect(validate.validateAsciiHex("0123456789abcdef"));
    try std.testing.expect(validate.validateAsciiHex("0"));
    try std.testing.expect(validate.validateAsciiHex("A"));
    try std.testing.expect(validate.validateAsciiHex(""));
}

test "validateAsciiHex invalid" {
    try std.testing.expect(!validate.validateAsciiHex("G"));
    try std.testing.expect(!validate.validateAsciiHex("0123456789ABCDEG"));
    try std.testing.expect(!validate.validateAsciiHex(" "));  // space
    try std.testing.expect(!validate.validateAsciiHex("-"));  // dash
}

test "validateAsciiHex long string" {
    var buf: [64]u8 = undefined;
    for (0..64) |i| buf[i] = if (i % 2 == 0) 'A' else '0';
    try std.testing.expect(validate.validateAsciiHex(&buf));
    buf[32] = 'G';
    try std.testing.expect(!validate.validateAsciiHex(&buf));
}

// ═══════════════════════════════════════════════════════════════════════════
// Required Fields Rules
// ═══════════════════════════════════════════════════════════════════════════

test "RulesV1987 authorization request" {
    // Authorization request (class=1, function=0) requires: 2,3,4,7,11,41,49
    const rules = validate.RulesV1987;
    try std.testing.expect(rules.len > 0);
    // Find the rule for class=1, function=0
    var found = false;
    for (&rules) |rule| {
        if (rule.msg_class == 1 and rule.msg_function == 0) {
            found = true;
            try std.testing.expectEqual(@as(usize, 7), rule.required.len);
        }
    }
    try std.testing.expect(found);
}

test "RulesV1987 network management request" {
    const rules = validate.RulesV1987;
    var found = false;
    for (&rules) |rule| {
        if (rule.msg_class == 8 and rule.msg_function == 0) {
            found = true;
            // Requires: 7, 11, 41
            try std.testing.expectEqual(@as(usize, 3), rule.required.len);
        }
    }
    try std.testing.expect(found);
}
