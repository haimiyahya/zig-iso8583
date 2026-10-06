//! Comptime specification engine for ISO 8583 message formats.
//!
//! Provides a DSL to define message specs at comptime. The spec is used to:
//! - Generate field dispatch tables (no runtime hash maps)
//! - Validate field IDs and types at comptime
//! - Specialize decoder/encoder code per spec
//!
//! Pre-built specs for ISO 8583:1987, 1993, and 2003 are included.

const std = @import("std");
const encoding = @import("encoding.zig");
const field_mod = @import("field.zig");

pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;
pub const FieldDescriptor = field_mod.FieldDescriptor;

// ─── ISO 8583 Version ──────────────────────────────────────────────────────

pub const Version = enum {
    v1987,
    v1993,
    v2003,
};

// ─── MTI Encoding ──────────────────────────────────────────────────────────

/// How the MTI is encoded on the wire.
pub const MtiEncoding = enum {
    ascii, // 4 ASCII bytes: "0100"
    bcd, // 2 BCD bytes: 0x01 0x00
};

/// How the bitmap is encoded on the wire.
pub const BitmapEncoding = enum {
    binary, // 8 or 16 raw bytes
    bcd, // 16 or 32 BCD bytes (each byte → 2 hex digits)
};

// ─── Spec Definition ───────────────────────────────────────────────────────

/// Configuration for a message specification.
pub const SpecConfig = struct {
    version: Version,
    mti_encoding: MtiEncoding = .ascii,
    bitmap_encoding: BitmapEncoding = .binary,
    fields: []const FieldDescriptor,
};

/// The compiled specification. All data is comptime-known.
pub const Spec = struct {
    version: Version,
    mti_encoding: MtiEncoding,
    bitmap_encoding: BitmapEncoding,
    fields: []const FieldDescriptor,
    /// Computed lookup table: field_id → index in fields array.
    /// Built at comptime for O(1) field resolution.
    field_index: [129]i16, // 0–128; -1 = not in spec

    const Self = @This();

    /// Define a spec at comptime.
    pub fn define(comptime config: SpecConfig) Spec {
        comptime var field_index: [129]i16 = .{-1} ** 129;
        comptime for (config.fields, 0..) |desc, i| {
            if (desc.id >= 2 and desc.id <= 128) {
                field_index[desc.id] = @intCast(i);
            }
        };

        return .{
            .version = config.version,
            .mti_encoding = config.mti_encoding,
            .bitmap_encoding = config.bitmap_encoding,
            .fields = config.fields,
            .field_index = field_index,
        };
    }

    /// Look up a field descriptor by ID. Returns null if not in spec.
    pub fn lookup(self: Self, field_id: usize) ?FieldDescriptor {
        if (field_id < 2 or field_id > 128) return null;
        const idx = self.field_index[field_id];
        if (idx < 0) return null;
        return self.fields[@intCast(idx)];
    }

    /// Runtime lookup by field ID.
    pub fn lookupRuntime(self: Self, field_id: usize) ?FieldDescriptor {
        if (field_id < 2 or field_id > 128) return null;
        const idx = self.field_index[field_id];
        if (idx < 0) return null;
        return self.fields[@intCast(idx)];
    }

    /// Check if a field is defined in this spec.
    pub fn hasField(self: Self, field_id: usize) bool {
        return self.lookupRuntime(field_id) != null;
    }

    /// Return the number of fields defined in this spec.
    pub fn fieldCount(self: Self) usize {
        return self.fields.len;
    }

    /// Get MTI byte length based on encoding.
    pub fn mtiLen(self: Self) usize {
        return switch (self.mti_encoding) {
            .ascii => 4,
            .bcd => 2,
        };
    }

    /// Get the minimum bitmap byte length (primary only = 8 bytes).
    pub fn bitmapLen(self: Self) usize {
        return switch (self.bitmap_encoding) {
            .binary => 8,
            .bcd => 16,
        };
    }
};

// ─── Pre-built Specs ───────────────────────────────────────────────────────

/// ISO 8583:1987 base spec with common financial transaction fields.
pub const SpecV1987 = Spec.define(.{
    .version = .v1987,
    .mti_encoding = .ascii,
    .bitmap_encoding = .binary,
    .fields = &.{
        // Primary account number
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        // Processing code
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        // Amount, transaction
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        // Amount, settlement
        field_mod.field(5, .fixed_12, .ascii_numeric, .{}),
        // Amount, cardholder billing
        field_mod.field(6, .fixed_12, .ascii_numeric, .{}),
        // Transmission date & time
        field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
        // Amount, cardholder billing fee
        field_mod.field(8, .fixed_12, .ascii_numeric, .{}),
        // Conversion rate, settlement
        field_mod.field(9, .fixed_8, .ascii_numeric, .{}),
        // Conversion rate, cardholder billing
        field_mod.field(10, .fixed_8, .ascii_numeric, .{}),
        // System trace audit number (STAN)
        field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
        // Time, local transaction
        field_mod.field(12, .fixed_6, .ascii_numeric, .{}),
        // Date, local transaction
        field_mod.field(13, .fixed_4, .ascii_numeric, .{}),
        // Date, expiration
        field_mod.field(14, .fixed_4, .ascii_numeric, .{}),
        // Conversion rate, settlement
        field_mod.field(15, .fixed_6, .ascii_numeric, .{}),
        // Date, settlement
        field_mod.field(16, .fixed_4, .ascii_numeric, .{}),
        // Date, capture
        field_mod.field(17, .fixed_4, .ascii_numeric, .{}),
        // Merchant type (MCC)
        field_mod.field(18, .fixed_4, .ascii_numeric, .{}),
        // Acquiring institution country code
        field_mod.field(19, .fixed_3, .ascii_numeric, .{}),
        // PAN extended, country code
        field_mod.field(20, .fixed_3, .ascii_numeric, .{}),
        // Transaction life cycle ID
        field_mod.field(22, .fixed_3, .ascii_numeric, .{}),
        // Card sequence number
        field_mod.field(23, .fixed_3, .ascii_numeric, .{}),
        // Function code
        field_mod.field(24, .fixed_3, .ascii_numeric, .{}),
        // Message reason code
        field_mod.field(25, .fixed_2, .ascii_numeric, .{}),
        // Card acceptor business code
        field_mod.field(26, .fixed_2, .ascii_numeric, .{}),
        // Receiving institution ID code
        field_mod.field(32, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        // Forwarding institution ID code
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        // Primary account number, extended
        field_mod.field(34, .llvar, .ascii_numeric, .{ .max_len = 28 }),
        // Track 2 data
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37 }),
        // Track 3 data
        field_mod.field(36, .lllvar, .ascii_alpha, .{ .max_len = 104 }),
        // Retrieval reference number
        field_mod.field(37, .fixed_12, .ascii_alpha, .{}),
        // Approval code
        field_mod.field(38, .fixed_6, .ascii_alpha, .{}),
        // Action code
        field_mod.field(39, .fixed_2, .ascii_alpha, .{}),
        // Service code
        field_mod.field(40, .fixed_3, .ascii_numeric, .{}),
        // Card acceptor terminal ID
        field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
        // Card acceptor ID code
        field_mod.field(42, .fixed_15, .ascii_alpha, .{}),
        // Card acceptor name/location
        field_mod.field(43, .fixed_40, .ascii_alpha, .{}),
        // Additional response data
        field_mod.field(44, .llvar, .ascii_alpha, .{ .max_len = 99 }),
        // Track 1 data
        field_mod.field(45, .llvar, .ascii_alpha, .{ .max_len = 76 }),
        // Additional data — national
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999, .has_subfields = true }),
        // Currency code, transaction
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        // Currency code, settlement
        field_mod.field(50, .fixed_3, .ascii_numeric, .{}),
        // PIN data
        field_mod.field(52, .fixed_8, .binary, .{}),
        // Security related control information
        field_mod.field(53, .fixed_16, .ascii_numeric, .{}),
        // Amounts, additional
        field_mod.field(54, .lllvar, .ascii_alpha, .{ .max_len = 120 }),
        // Integrated circuit card (ICC) system related data
        field_mod.field(55, .lllvar, .binary, .{ .max_len = 999 }),
        // Message reason code
        field_mod.field(56, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        // Additional data — national
        field_mod.field(59, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        // Reserved national
        field_mod.field(60, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        // Reserved national
        field_mod.field(61, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        // Additional data — private
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999, .has_subfields = true }),
        // Reserved private
        field_mod.field(63, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        // Message authentication code (MAC)
        field_mod.field(64, .fixed_8, .binary, .{}),
        // Bit map, tertiary
        field_mod.field(65, .fixed_1, .binary, .{}),
        // Settlement code
        field_mod.field(66, .fixed_1, .ascii_numeric, .{}),
        // Additional data — private
        field_mod.field(70, .fixed_3, .ascii_numeric, .{}),
        // Message number
        field_mod.field(71, .fixed_4, .ascii_numeric, .{}),
        // Message number
        field_mod.field(72, .fixed_4, .ascii_numeric, .{}),
        // Action date
        field_mod.field(73, .fixed_6, .ascii_numeric, .{}),
        // Credits, number
        field_mod.field(75, .fixed_10, .ascii_numeric, .{}),
        // Debits, number
        field_mod.field(76, .fixed_10, .ascii_numeric, .{}),
        // Credits, reversal number
        field_mod.field(77, .fixed_10, .ascii_numeric, .{}),
        // Debits, reversal number
        field_mod.field(78, .fixed_10, .ascii_numeric, .{}),
        // Credits, fee number
        field_mod.field(79, .fixed_10, .ascii_numeric, .{}),
        // Debits, fee number
        field_mod.field(80, .fixed_10, .ascii_numeric, .{}),
        // Currency code, cardholder billing
        field_mod.field(81, .fixed_3, .ascii_numeric, .{}),
        // Currency code, settlement
        field_mod.field(82, .fixed_3, .ascii_numeric, .{}),
        // Network management information code
        field_mod.field(90, .fixed_42, .ascii_alpha, .{}),
        // File name
        field_mod.field(91, .fixed_1, .ascii_alpha, .{}),
        // Transaction destination institution ID
        field_mod.field(100, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        // Transaction originator institution ID
        field_mod.field(101, .llvar, .ascii_alpha, .{ .max_len = 11 }),
        // MAC2
        field_mod.field(128, .fixed_8, .binary, .{}),
    },
});

/// ISO 8583:1993 spec — extends v1987 with additional fields.
pub const SpecV1993 = Spec.define(.{
    .version = .v1993,
    .mti_encoding = .ascii,
    .bitmap_encoding = .binary,
    .fields = &.{
        // Common fields (same as v1987 for the most part)
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(5, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(6, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
        field_mod.field(9, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(10, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(12, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(13, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(14, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(15, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(18, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(22, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(23, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(25, .fixed_2, .ascii_numeric, .{}),
        field_mod.field(28, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(30, .fixed_24, .ascii_numeric, .{}),
        field_mod.field(32, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37 }),
        field_mod.field(37, .fixed_12, .ascii_alpha, .{}),
        field_mod.field(38, .fixed_6, .ascii_alpha, .{}),
        field_mod.field(39, .fixed_2, .ascii_alpha, .{}),
        field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
        field_mod.field(42, .fixed_15, .ascii_alpha, .{}),
        field_mod.field(43, .fixed_40, .ascii_alpha, .{}),
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(50, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(52, .fixed_8, .binary, .{}),
        field_mod.field(53, .fixed_16, .ascii_numeric, .{}),
        field_mod.field(54, .lllvar, .ascii_alpha, .{ .max_len = 120 }),
        field_mod.field(55, .lllvar, .binary, .{ .max_len = 999 }),
        field_mod.field(61, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(63, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(64, .fixed_8, .binary, .{}),
        field_mod.field(70, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(71, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(72, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(73, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(93, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(94, .fixed_7, .ascii_alpha, .{}),
        field_mod.field(95, .fixed_42, .ascii_alpha, .{}),
        field_mod.field(100, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(101, .llvar, .ascii_alpha, .{ .max_len = 11 }),
        field_mod.field(102, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(103, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(128, .fixed_8, .binary, .{}),
    },
});

/// ISO 8583:2003 spec — updated with new fields and formats.
pub const SpecV2003 = Spec.define(.{
    .version = .v2003,
    .mti_encoding = .ascii,
    .bitmap_encoding = .binary,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(5, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(6, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
        field_mod.field(9, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(10, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(12, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(13, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(14, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(15, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(18, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(22, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(23, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(25, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(28, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(32, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37 }),
        field_mod.field(37, .fixed_12, .ascii_alpha, .{}),
        field_mod.field(38, .fixed_6, .ascii_alpha, .{}),
        field_mod.field(39, .fixed_2, .ascii_alpha, .{}),
        field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
        field_mod.field(42, .fixed_15, .ascii_alpha, .{}),
        field_mod.field(43, .fixed_40, .ascii_alpha, .{}),
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(50, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(52, .fixed_8, .binary, .{}),
        field_mod.field(55, .lllvar, .binary, .{ .max_len = 999 }),
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(64, .fixed_8, .binary, .{}),
        field_mod.field(70, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(87, .llvar, .ascii_alpha, .{ .max_len = 24 }),
        field_mod.field(88, .llvar, .ascii_alpha, .{ .max_len = 24 }),
        field_mod.field(89, .llvar, .ascii_alpha, .{ .max_len = 17 }),
        field_mod.field(90, .fixed_42, .ascii_alpha, .{}),
        field_mod.field(100, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(101, .llvar, .ascii_alpha, .{ .max_len = 11 }),
        field_mod.field(102, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(103, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(122, .llvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(123, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(124, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(125, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(126, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(127, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(128, .fixed_8, .binary, .{}),
    },
});

// ─── Tests ─────────────────────────────────────────────────────────────────

test "Spec.define basic" {
    const test_spec = comptime Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
            field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
            field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        },
    });

    try std.testing.expectEqual(Version.v1987, test_spec.version);
    try std.testing.expectEqual(@as(usize, 3), test_spec.fieldCount());
    try std.testing.expect(test_spec.hasField(2));
    try std.testing.expect(test_spec.hasField(3));
    try std.testing.expect(test_spec.hasField(4));
    try std.testing.expect(!test_spec.hasField(5));
}

test "Spec.lookup comptime" {
    const desc = SpecV1987.lookup(2);
    try std.testing.expect(desc != null);
    try std.testing.expectEqual(LengthType.llvar, desc.?.length_type);
    try std.testing.expectEqual(FieldEncoding.ascii_numeric, desc.?.encoding);
    try std.testing.expectEqual(@as(usize, 19), desc.?.max_len);

    const desc3 = SpecV1987.lookup(3);
    try std.testing.expect(desc3 != null);
    try std.testing.expectEqual(LengthType.fixed_6, desc3.?.length_type);
}

test "Spec lookup non-existent field" {
    const desc = SpecV1987.lookup(1);
    try std.testing.expect(desc == null);
}

test "SpecV1987 basic checks" {
    try std.testing.expectEqual(Version.v1987, SpecV1987.version);
    try std.testing.expectEqual(MtiEncoding.ascii, SpecV1987.mti_encoding);
    try std.testing.expectEqual(BitmapEncoding.binary, SpecV1987.bitmap_encoding);
    try std.testing.expect(SpecV1987.hasField(2));
    try std.testing.expect(SpecV1987.hasField(4));
    try std.testing.expect(SpecV1987.hasField(48));
    try std.testing.expect(SpecV1987.hasField(52));
    try std.testing.expect(SpecV1987.hasField(128));
}

test "SpecV1993 basic checks" {
    try std.testing.expectEqual(Version.v1993, SpecV1993.version);
    try std.testing.expect(SpecV1993.hasField(2));
    try std.testing.expect(SpecV1993.hasField(102));
}

test "SpecV2003 basic checks" {
    try std.testing.expectEqual(Version.v2003, SpecV2003.version);
    try std.testing.expect(SpecV2003.hasField(2));
    try std.testing.expect(SpecV2003.hasField(122));
    try std.testing.expect(SpecV2003.hasField(127));
}

test "Spec.mtiLen" {
    const ascii_spec = comptime Spec.define(.{
        .version = .v1987,
        .mti_encoding = .ascii,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 4), ascii_spec.mtiLen());

    const bcd_spec = comptime Spec.define(.{
        .version = .v1987,
        .mti_encoding = .bcd,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 2), bcd_spec.mtiLen());
}
