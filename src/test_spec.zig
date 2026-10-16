//! Comprehensive tests for the spec module.
//! Covers custom specs, field lookups, pre-built specs, version differences.

const std = @import("std");
const spec_mod = @import("spec.zig");
const field_mod = @import("field.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Custom Spec Definition
// ═══════════════════════════════════════════════════════════════════════════

test "Spec.define minimal spec" {
    const s = spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        },
    });
    try std.testing.expectEqual(spec_mod.Version.v1987, s.version);
    try std.testing.expectEqual(@as(usize, 1), s.fieldCount());
    try std.testing.expect(s.hasField(2));
    try std.testing.expect(!s.hasField(3));
}

test "Spec.define with all encodings" {
    const s = spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
            field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
            field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
            field_mod.field(52, .fixed_8, .binary, .{}),
            field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        },
    });
    try std.testing.expectEqual(@as(usize, 5), s.fieldCount());

    const de2 = s.lookup(2).?;
    try std.testing.expectEqual(spec_mod.LengthType.llvar, de2.length_type);
    try std.testing.expectEqual(spec_mod.FieldEncoding.ascii_numeric, de2.encoding);
    try std.testing.expectEqual(@as(usize, 19), de2.max_len);

    const de52 = s.lookup(52).?;
    try std.testing.expectEqual(spec_mod.LengthType.fixed_8, de52.length_type);
    try std.testing.expectEqual(spec_mod.FieldEncoding.binary, de52.encoding);
}

test "Spec.define with custom MTI and bitmap encoding" {
    const s = spec_mod.Spec.define(.{
        .version = .v1993,
        .mti_encoding = .bcd,
        .bitmap_encoding = .bcd,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        },
    });
    try std.testing.expectEqual(spec_mod.MtiEncoding.bcd, s.mti_encoding);
    try std.testing.expectEqual(spec_mod.BitmapEncoding.bcd, s.bitmap_encoding);
    try std.testing.expectEqual(@as(usize, 2), s.mtiLen());
    try std.testing.expectEqual(@as(usize, 16), s.bitmapLen());
}

test "Spec.define with LLLLVAR" {
    const s = spec_mod.Spec.define(.{
        .version = .v2003,
        .fields = &.{
            field_mod.field(48, .llllvar, .ascii_alpha, .{ .max_len = 9999 }),
        },
    });
    const de48 = s.lookup(48).?;
    try std.testing.expectEqual(spec_mod.LengthType.llllvar, de48.length_type);
    try std.testing.expectEqual(@as(usize, 9999), de48.max_len);
}

// ═══════════════════════════════════════════════════════════════════════════
// Field Lookup
// ═══════════════════════════════════════════════════════════════════════════

test "Spec.lookup existing field" {
    const s = spec_mod.SpecV1987;
    const de2 = s.lookup(2);
    try std.testing.expect(de2 != null);
    try std.testing.expectEqual(spec_mod.LengthType.llvar, de2.?.length_type);
}

test "Spec.lookup non-existent field" {
    const s = spec_mod.SpecV1987;
    try std.testing.expectEqual(@as(?spec_mod.FieldDescriptor, null), s.lookup(1));
    try std.testing.expectEqual(@as(?spec_mod.FieldDescriptor, null), s.lookup(21)); // Not in v1987 spec
}

test "Spec.lookup out of range" {
    const s = spec_mod.SpecV1987;
    try std.testing.expectEqual(@as(?spec_mod.FieldDescriptor, null), s.lookup(0));
    try std.testing.expectEqual(@as(?spec_mod.FieldDescriptor, null), s.lookup(129));
    try std.testing.expectEqual(@as(?spec_mod.FieldDescriptor, null), s.lookup(200));
}

test "Spec.lookupRuntime matches lookup" {
    const s = spec_mod.SpecV1987;
    // Check a few fields both ways
    const ids = [_]usize{ 2, 3, 4, 48, 52, 128 };
    for (&ids) |id| {
        const ct = s.lookup(id);
        const rt = s.lookupRuntime(id);
        if (ct) |desc| {
            try std.testing.expect(rt != null);
            try std.testing.expectEqual(desc.id, rt.?.id);
            try std.testing.expectEqual(desc.length_type, rt.?.length_type);
            try std.testing.expectEqual(desc.encoding, rt.?.encoding);
        } else {
            try std.testing.expect(rt == null);
        }
    }
}

test "Spec.hasField" {
    const s = spec_mod.SpecV1987;
    try std.testing.expect(s.hasField(2));
    try std.testing.expect(s.hasField(4));
    try std.testing.expect(s.hasField(48));
    try std.testing.expect(s.hasField(52));
    try std.testing.expect(s.hasField(128));
    try std.testing.expect(!s.hasField(1));
    try std.testing.expect(!s.hasField(0));
    try std.testing.expect(!s.hasField(129));
}

// ═══════════════════════════════════════════════════════════════════════════
// Spec Properties
// ═══════════════════════════════════════════════════════════════════════════

test "Spec.mtiLen" {
    const ascii_spec = spec_mod.Spec.define(.{
        .version = .v1987,
        .mti_encoding = .ascii,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 4), ascii_spec.mtiLen());

    const bcd_spec = spec_mod.Spec.define(.{
        .version = .v1987,
        .mti_encoding = .bcd,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 2), bcd_spec.mtiLen());
}

test "Spec.bitmapLen" {
    const binary_spec = spec_mod.Spec.define(.{
        .version = .v1987,
        .bitmap_encoding = .binary,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 8), binary_spec.bitmapLen());

    const bcd_spec = spec_mod.Spec.define(.{
        .version = .v1987,
        .bitmap_encoding = .bcd,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 16), bcd_spec.bitmapLen());
}

test "Spec.fieldCount" {
    try std.testing.expect(spec_mod.SpecV1987.fieldCount() > 30);
    try std.testing.expect(spec_mod.SpecV1993.fieldCount() > 20);
    try std.testing.expect(spec_mod.SpecV2003.fieldCount() > 20);
}

// ═══════════════════════════════════════════════════════════════════════════
// Pre-built Spec Verification
// ═══════════════════════════════════════════════════════════════════════════

test "SpecV1987 key fields" {
    const s = spec_mod.SpecV1987;
    try std.testing.expectEqual(spec_mod.Version.v1987, s.version);

    // DE2: PAN
    const de2 = s.lookup(2).?;
    try std.testing.expectEqual(spec_mod.LengthType.llvar, de2.length_type);
    try std.testing.expectEqual(spec_mod.FieldEncoding.ascii_numeric, de2.encoding);
    try std.testing.expectEqual(@as(usize, 19), de2.max_len);

    // DE3: Processing code
    const de3 = s.lookup(3).?;
    try std.testing.expectEqual(spec_mod.LengthType.fixed_6, de3.length_type);

    // DE4: Amount
    const de4 = s.lookup(4).?;
    try std.testing.expectEqual(spec_mod.LengthType.fixed_12, de4.length_type);

    // DE52: PIN block
    const de52 = s.lookup(52).?;
    try std.testing.expectEqual(spec_mod.FieldEncoding.binary, de52.encoding);

    // DE48: Additional data (has subfields)
    const de48 = s.lookup(48).?;
    try std.testing.expectEqual(spec_mod.LengthType.lllvar, de48.length_type);
    try std.testing.expect(de48.has_subfields);

    // DE128: MAC
    const de128 = s.lookup(128).?;
    try std.testing.expectEqual(spec_mod.LengthType.fixed_8, de128.length_type);
    try std.testing.expectEqual(spec_mod.FieldEncoding.binary, de128.encoding);
}

test "SpecV1993 key fields" {
    const s = spec_mod.SpecV1993;
    try std.testing.expectEqual(spec_mod.Version.v1993, s.version);
    try std.testing.expect(s.hasField(2));
    try std.testing.expect(s.hasField(102)); // v1993 adds DE102
    try std.testing.expect(s.hasField(103));
}

test "SpecV2003 key fields" {
    const s = spec_mod.SpecV2003;
    try std.testing.expectEqual(spec_mod.Version.v2003, s.version);
    try std.testing.expect(s.hasField(2));
    try std.testing.expect(s.hasField(122)); // v2003 adds DE122-127
    try std.testing.expect(s.hasField(123));
    try std.testing.expect(s.hasField(124));
    try std.testing.expect(s.hasField(125));
    try std.testing.expect(s.hasField(126));
    try std.testing.expect(s.hasField(127));
}

test "SpecV1987 vs V1993 differences" {
    // V1993 should have fields that V1987 doesn't
    try std.testing.expect(!spec_mod.SpecV1987.hasField(102));
    try std.testing.expect(spec_mod.SpecV1993.hasField(102));
}

test "SpecV1987 vs V2003 differences" {
    // V2003 should have fields that V1987 doesn't
    try std.testing.expect(!spec_mod.SpecV1987.hasField(122));
    try std.testing.expect(spec_mod.SpecV2003.hasField(122));
}

// ═══════════════════════════════════════════════════════════════════════════
// Version Enum
// ═══════════════════════════════════════════════════════════════════════════

test "Version enum values" {
    try std.testing.expectEqual(spec_mod.Version.v1987, spec_mod.Version.v1987);
    try std.testing.expectEqual(spec_mod.Version.v1993, spec_mod.Version.v1993);
    try std.testing.expectEqual(spec_mod.Version.v2003, spec_mod.Version.v2003);
}

// ═══════════════════════════════════════════════════════════════════════════
// Comptime field-set validation
// ═══════════════════════════════════════════════════════════════════════════

test "field-set validation: valid set passes" {
    const fields = [_]field_mod.FieldDescriptor{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19, .name = "PAN" }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
    };
    try std.testing.expect(spec_mod.firstInvalidField(&fields) == null);
}

test "field-set validation: out-of-range ID detected" {
    const fields = [_]field_mod.FieldDescriptor{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(200, .fixed_6, .ascii_numeric, .{}), // invalid
    };
    const problem = spec_mod.firstInvalidField(&fields).?;
    try std.testing.expectEqual(spec_mod.FieldProblem.Kind.id_out_of_range, problem.kind);
    try std.testing.expectEqual(@as(u8, 200), problem.id);
}

test "field-set validation: duplicate ID detected" {
    const fields = [_]field_mod.FieldDescriptor{
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}), // duplicate
    };
    const problem = spec_mod.firstInvalidField(&fields).?;
    try std.testing.expectEqual(spec_mod.FieldProblem.Kind.duplicate, problem.kind);
    try std.testing.expectEqual(@as(u8, 4), problem.id);
}

test "field-set validation: variable field without max_len detected" {
    const fields = [_]field_mod.FieldDescriptor{
        field_mod.field(48, .lllvar, .ascii_alpha, .{}), // missing max_len
    };
    const problem = spec_mod.firstInvalidField(&fields).?;
    try std.testing.expectEqual(spec_mod.FieldProblem.Kind.missing_max_len, problem.kind);
    try std.testing.expectEqual(@as(u8, 48), problem.id);
}

// Spec.define itself rejects these at compile time; the compile-failure path
// is exercised by CI building the pre-built specs (any regression there is a
// build break, not a runtime fault).

// ═══════════════════════════════════════════════════════════════════════════
// Field names (debugging)
// ═══════════════════════════════════════════════════════════════════════════

test "SpecV1987 field names" {
    try std.testing.expectEqualStrings("Primary account number", spec_mod.SpecV1987.nameOf(2).?);
    try std.testing.expectEqualStrings("Amount, transaction", spec_mod.SpecV1987.nameOf(4).?);
    try std.testing.expectEqualStrings("Network management information code", spec_mod.SpecV1987.nameOf(70).?);
    try std.testing.expect(spec_mod.SpecV1987.nameOf(21) == null); // not in spec
}

test "writeFieldName: named and fallback" {
    const Named = comptime spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(4, .fixed_12, .ascii_numeric, .{ .name = "Amount, transaction" }),
        },
    });
    const Unnamed = comptime spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        },
    });

    var buf: [64]u8 = undefined;

    var fbs1 = std.io.fixedBufferStream(&buf);
    try Named.writeFieldName(4, fbs1.writer());
    try std.testing.expectEqualStrings("Amount, transaction", fbs1.getWritten());

    var fbs2 = std.io.fixedBufferStream(&buf);
    try Unnamed.writeFieldName(4, fbs2.writer());
    try std.testing.expectEqualStrings("DE4", fbs2.getWritten());

    var fbs3 = std.io.fixedBufferStream(&buf);
    try spec_mod.SpecV1987.writeFieldName(127, fbs3.writer()); // not in spec
    try std.testing.expectEqualStrings("DE127", fbs3.getWritten());
}

test "Spec unknown_fields default is reject" {
    const s = spec_mod.Spec.define(.{
        .version = .v1987,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(spec_mod.UnknownFieldPolicy.reject, s.unknown_fields);
}
