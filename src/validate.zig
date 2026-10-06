//! Field validation for ISO 8583 messages.
//!
//! Uses SIMD-accelerated validation for ASCII digit and alphanumeric checks.
//! Comptime rules can be defined per-spec for required fields per MTI.

const std = @import("std");
const spec_mod = @import("spec.zig");
const field_mod = @import("field.zig");
const encoding = @import("encoding.zig");
const simd = @import("simd.zig");

pub const FieldEncoding = encoding.FieldEncoding;

// ─── Validation Errors ─────────────────────────────────────────────────────

pub const ValidationError = error{
    InvalidDigits,
    InvalidAlnum,
    InvalidBinary,
    InvalidLength,
    EmptyField,
};

// ─── Field Validation ──────────────────────────────────────────────────────

/// Validate a field's data according to its encoding.
/// Uses SIMD for ASCII validation where possible.
pub fn validateFieldData(data: []const u8, enc: FieldEncoding) ValidationError!void {
    if (data.len == 0) return error.EmptyField;

    switch (enc) {
        .ascii_numeric => {
            if (!simd.validateAsciiDigits(data)) return error.InvalidDigits;
        },
        .ascii_alpha => {
            if (!simd.validateAsciiAlnum(data)) return error.InvalidAlnum;
        },
        .ascii_binary => {
            // ASCII hex: each byte must be 0-9, A-F, a-f
            for (data) |b| {
                const is_digit = b >= 0x30 and b <= 0x39;
                const is_upper = b >= 0x41 and b <= 0x46;
                const is_lower = b >= 0x61 and b <= 0x66;
                if (!is_digit and !is_upper and !is_lower) return error.InvalidAlnum;
            }
        },
        .bcd => {
            // BCD: each nibble must be 0-9
            for (data) |byte| {
                const hi = (byte >> 4) & 0x0F;
                const lo = byte & 0x0F;
                if (hi > 9 or lo > 9) return error.InvalidDigits;
            }
        },
        .binary => {
            // Binary: no validation needed, any byte is valid
        },
    }
}

// ─── MTI-Based Required Fields ─────────────────────────────────────────────

/// A rule defining required fields for a given MTI class+function.
pub const RequiredFieldsRule = struct {
    msg_class: u4,
    msg_function: u4,
    required: []const u8, // field IDs that must be present
};

/// Validate that a message has all required fields for its MTI.
/// `rules` is a comptime-known slice of RequiredFieldsRule.
pub fn validateRequiredFields(
    is_present: fn (usize) bool,
    msg_class: u4,
    msg_function: u4,
    comptime rules: []const RequiredFieldsRule,
) !void {
    inline for (rules) |rule| {
        if (rule.msg_class == msg_class and rule.msg_function == msg_function) {
            inline for (rule.required) |field_id| {
                if (!is_present(field_id)) {
                    return error.MissingRequiredField;
                }
            }
            return;
        }
    }
}

// ─── Common Validation Rules ───────────────────────────────────────────────

/// Common required fields for ISO 8583:1987 authorization requests (0100).
pub const RulesV1987 = [_]RequiredFieldsRule{
    .{
        .msg_class = 1, // authorization
        .msg_function = 0, // request
        .required = &.{ 2, 3, 4, 7, 11, 41, 49 },
    },
    .{
        .msg_class = 1, // authorization
        .msg_function = 1, // response
        .required = &.{ 2, 3, 4, 7, 11, 39, 41, 49 },
    },
    .{
        .msg_class = 2, // financial
        .msg_function = 0, // request
        .required = &.{ 2, 3, 4, 7, 11, 41, 49 },
    },
    .{
        .msg_class = 4, // reversal
        .msg_function = 0, // request
        .required = &.{ 2, 3, 4, 7, 11, 41, 49 },
    },
    .{
        .msg_class = 8, // network management
        .msg_function = 0, // request
        .required = &.{ 7, 11, 41 },
    },
};

// ─── SIMD Hex Validation ───────────────────────────────────────────────────

/// Validate ASCII hex bytes using SIMD (16 bytes at a time).
pub fn validateAsciiHex(slice: []const u8) bool {
    if (slice.len == 0) return true;

    const Vec = @Vector(16, u8);
    const digit_lo: Vec = @splat(0x30);
    const digit_hi: Vec = @splat(0x39);
    const upper_lo: Vec = @splat(0x41);
    const upper_hi: Vec = @splat(0x46);
    const lower_lo: Vec = @splat(0x61);
    const lower_hi: Vec = @splat(0x66);

    var i: usize = 0;
    while (i + 16 <= slice.len) : (i += 16) {
        const v: Vec = slice[i..][0..16].*;
        const BoolVec = @Vector(16, bool);
        const falses: BoolVec = @splat(false);
        const trues: BoolVec = @splat(true);
        const is_digit = @select(bool, v >= digit_lo, v <= digit_hi, falses);
        const is_upper = @select(bool, v >= upper_lo, v <= upper_hi, falses);
        const is_lower = @select(bool, v >= lower_lo, v <= lower_hi, falses);
        const digit_or_upper = @select(bool, is_digit, trues, is_upper);
        const valid = @select(bool, digit_or_upper, trues, is_lower);
        if (@reduce(.And, valid) == false) return false;
    }

    // Scalar tail
    for (slice[i..]) |b| {
        const is_digit = b >= 0x30 and b <= 0x39;
        const is_upper = b >= 0x41 and b <= 0x46;
        const is_lower = b >= 0x61 and b <= 0x66;
        if (!is_digit and !is_upper and !is_lower) return false;
    }
    return true;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "validateFieldData ascii_numeric" {
    try validateFieldData("123456", .ascii_numeric);
    try std.testing.expectError(error.InvalidDigits, validateFieldData("123A56", .ascii_numeric));
}

test "validateFieldData ascii_alpha" {
    try validateFieldData("ABC123", .ascii_alpha);
    try std.testing.expectError(error.InvalidAlnum, validateFieldData("ABC 123", .ascii_alpha));
}

test "validateFieldData binary" {
    // Any bytes are valid for binary encoding
    try validateFieldData(&[_]u8{ 0x00, 0xFF, 0x80 }, .binary);
}

test "validateFieldData bcd" {
    try validateFieldData(&[_]u8{ 0x12, 0x34 }, .bcd);
    try std.testing.expectError(error.InvalidDigits, validateFieldData(&[_]u8{ 0xAB }, .bcd));
}

test "validateAsciiHex SIMD" {
    try std.testing.expect(validateAsciiHex("0123456789ABCDEF"));
    try std.testing.expect(validateAsciiHex("0123456789abcdef"));
    try std.testing.expect(!validateAsciiHex("0123456789ABCDEG"));
}

test "validateFieldData empty" {
    try std.testing.expectError(error.EmptyField, validateFieldData("", .ascii_numeric));
}
