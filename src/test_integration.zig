//! Comprehensive integration tests for decode/encode/round-trip.
//! Covers various message types, field encodings, error cases, and edge conditions.

const std = @import("std");
const spec_mod = @import("spec.zig");
const bitmap_mod = @import("bitmap.zig");
const mti_mod = @import("mti.zig");
const field_mod = @import("field.zig");
const encoding = @import("encoding.zig");
const decoder_mod = @import("decoder.zig");
const encoder_mod = @import("encoder.zig");

const Message = decoder_mod.Message;
const Bitmap = bitmap_mod.Bitmap;
const Spec = spec_mod.Spec;
const encode = encoder_mod.encode;
const setMti = encoder_mod.setMti;
const setField = encoder_mod.setField;
const setFieldPadded = encoder_mod.setFieldPadded;
const setFieldInt = encoder_mod.setFieldInt;

// ═══════════════════════════════════════════════════════════════════════════
// Test specs
// ═══════════════════════════════════════════════════════════════════════════

/// Minimal spec for basic tests
const BasicSpec = Spec.define(.{
    .version = .v1987,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
        field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
    },
});

/// Spec with variable-length fields
const VarSpec = Spec.define(.{
    .version = .v1987,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37 }),
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(54, .lllvar, .ascii_alpha, .{ .max_len = 120 }),
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
    },
});

/// Spec with binary fields
const BinarySpec = Spec.define(.{
    .version = .v1987,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(52, .fixed_8, .binary, .{}),
        field_mod.field(64, .fixed_8, .binary, .{}),
    },
});

/// Spec with BCD MTI
const BcdMtiSpec = Spec.define(.{
    .version = .v1987,
    .mti_encoding = .bcd,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
    },
});

/// Spec with BCD bitmap
const BcdBitmapSpec = Spec.define(.{
    .version = .v1987,
    .bitmap_encoding = .bcd,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
    },
});

// ═══════════════════════════════════════════════════════════════════════════
// Decode Tests
// ═══════════════════════════════════════════════════════════════════════════

test "decode authorization request (0100)" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    // Build: MTI=0100, fields 2,3,4,7,11,41,49
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("0100");
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(7);
    bm.set(11);
    bm.set(41);
    bm.set(49);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111"); // DE2: PAN
    try w.writeAll("000000"); // DE3
    try w.writeAll("000000001000"); // DE4
    try w.writeAll("0615123456"); // DE7
    try w.writeAll("000123"); // DE11
    try w.writeAll("TERM0001"); // DE41
    try w.writeAll("840"); // DE49

    try msg.decode(buf.items);
    try std.testing.expectEqual(mti_mod.MsgClass.authorization, msg.mti.class);
    try std.testing.expectEqual(mti_mod.MsgFunction.request, msg.mti.function);
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
    try std.testing.expectEqual(@as(?u64, 4111111111111111), msg.getFieldInt(2));
    try std.testing.expectEqualSlices(u8, "000000", msg.getField(3).?);
    try std.testing.expectEqualSlices(u8, "000000001000", msg.getField(4).?);
    try std.testing.expectEqual(@as(?u64, 1000), msg.getFieldInt(4));
    try std.testing.expectEqualSlices(u8, "840", msg.getField(49).?);
}

test "decode financial request (0200)" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("0200");
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(11);
    bm.set(41);
    bm.set(49);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111");
    try w.writeAll("000000");
    try w.writeAll("000000005000");
    try w.writeAll("000456");
    try w.writeAll("TERM0002");
    try w.writeAll("840");

    try msg.decode(buf.items);
    try std.testing.expectEqual(mti_mod.MsgClass.financial, msg.mti.class);
    try std.testing.expectEqual(@as(?u64, 5000), msg.getFieldInt(4));
}

test "decode network management (0800)" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("0800");
    var bm = Bitmap.init();
    bm.set(7);
    bm.set(11);
    bm.set(41);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("0615123456"); // DE7
    try w.writeAll("000001"); // DE11
    try w.writeAll("TERM0003"); // DE41

    try msg.decode(buf.items);
    try std.testing.expectEqual(mti_mod.MsgClass.network_management, msg.mti.class);
    try std.testing.expect(!msg.isPresent(2)); // PAN not present
    try std.testing.expect(msg.isPresent(7));
}

test "decode with variable-length fields (LLVAR, LLLVAR)" {
    var msg = try Message.init(std.testing.allocator, &VarSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("0200");
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(33);
    bm.set(48);
    bm.set(49);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111"); // DE2
    try w.writeAll("000000"); // DE3
    try w.writeAll("000000001000"); // DE4
    try w.writeAll("09612345678"); // DE33: LLVAR (prefix "09" → 9 digits = "612345678")
    try w.writeAll("016ABCDEFGHIJKLMNOP"); // DE48: LLLVAR (prefix "016" → 16 chars)
    try w.writeAll("840"); // DE49

    try msg.decode(buf.items);
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
    try std.testing.expectEqualSlices(u8, "612345678", msg.getField(33).?);
    try std.testing.expectEqualSlices(u8, "ABCDEFGHIJKLMNOP", msg.getField(48).?);
}

test "decode with binary fields" {
    var msg = try Message.init(std.testing.allocator, &BinarySpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("0200");
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    bm.set(52);
    bm.set(64);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111"); // DE2
    try w.writeAll("000000"); // DE3
    try w.writeAll("000000001000"); // DE4
    const pin_block = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    try w.writeAll(&pin_block); // DE52
    const mac = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
    try w.writeAll(&mac); // DE64

    try msg.decode(buf.items);
    try std.testing.expectEqualSlices(u8, &pin_block, msg.getField(52).?);
    try std.testing.expectEqualSlices(u8, &mac, msg.getField(64).?);
    // Binary fields should not have int_val
    try std.testing.expectEqual(@as(?u64, null), msg.getFieldInt(52));
}

test "decode with BCD MTI" {
    var msg = try Message.init(std.testing.allocator, &BcdMtiSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll(&[_]u8{ 0x02, 0x00 }); // BCD "0200"
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111");
    try w.writeAll("000000");
    try w.writeAll("000000001000");

    try msg.decode(buf.items);
    try std.testing.expectEqual(mti_mod.MsgClass.financial, msg.mti.class);
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
}

test "decode with BCD bitmap" {
    var msg = try Message.init(std.testing.allocator, &BcdBitmapSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("0100");
    // BCD bitmap: primary = 16 ASCII hex digits for 8 BCD bytes
    // Fields 2,3,4 → bitmap byte 0 = 0x70 (bits 2,3,4)
    // BCD representation: 0x70 → "70", then rest zeros → "00000000000000"
    // Full BCD primary: "7000000000000000"
    try w.writeAll("7000000000000000");
    try w.writeAll("164111111111111111");
    try w.writeAll("000000");
    try w.writeAll("000000001000");

    try msg.decode(buf.items);
    try std.testing.expect(msg.isPresent(2));
    try std.testing.expect(msg.isPresent(3));
    try std.testing.expect(msg.isPresent(4));
    try std.testing.expectEqualSlices(u8, "4111111111111111", msg.getField(2).?);
}

// ═══════════════════════════════════════════════════════════════════════════
// Encode Tests
// ═══════════════════════════════════════════════════════════════════════════

test "encode authorization request" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 49, "840");

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try encode(&msg, buf.writer());

    // MTI should be "0100"
    try std.testing.expectEqualSlices(u8, "0100", buf.items[0..4]);
    // Should have bitmap after MTI
    // Should contain the field data
    try std.testing.expect(buf.items.len > 4 + 8); // MTI + at least primary bitmap
}

test "encode with variable-length fields" {
    var msg = try Message.init(std.testing.allocator, &VarSpec);
    defer msg.deinit();

    setMti(&msg, 0, .financial, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 33, "12345678901");
    try setField(&msg, 48, "SOMEDATAHERE");
    try setField(&msg, 49, "840");

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try encode(&msg, buf.writer());

    // Decode back and verify
    var msg2 = try Message.init(std.testing.allocator, &VarSpec);
    defer msg2.deinit();
    try msg2.decode(buf.items);

    try std.testing.expectEqualSlices(u8, "4111111111111111", msg2.getField(2).?);
    try std.testing.expectEqualSlices(u8, "12345678901", msg2.getField(33).?);
    try std.testing.expectEqualSlices(u8, "SOMEDATAHERE", msg2.getField(48).?);
}

test "encode with binary fields" {
    var msg = try Message.init(std.testing.allocator, &BinarySpec);
    defer msg.deinit();

    setMti(&msg, 0, .financial, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 52, &[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF });
    try setField(&msg, 64, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE });

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try encode(&msg, buf.writer());

    // Decode back
    var msg2 = try Message.init(std.testing.allocator, &BinarySpec);
    defer msg2.deinit();
    try msg2.decode(buf.items);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF }, msg2.getField(52).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE }, msg2.getField(64).?);
}

// ═══════════════════════════════════════════════════════════════════════════
// Round-Trip Tests
// ═══════════════════════════════════════════════════════════════════════════

test "round-trip basic message" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 7, "0615123456");
    try setField(&msg, 11, "000123");
    try setField(&msg, 41, "TERM0001");
    try setField(&msg, 49, "840");

    var buf1 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf1.deinit();
    try encode(&msg, buf1.writer());

    var msg2 = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg2.deinit();
    try msg2.decode(buf1.items);

    var buf2 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf2.deinit();
    try encode(&msg2, buf2.writer());

    try std.testing.expectEqualSlices(u8, buf1.items, buf2.items);
}

test "round-trip with all variable-length types" {
    var msg = try Message.init(std.testing.allocator, &VarSpec);
    defer msg.deinit();

    setMti(&msg, 0, .financial, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "004000");
    try setField(&msg, 4, "000000001500");
    try setField(&msg, 33, "12345678");
    try setField(&msg, 35, "4111111111111111D2512201101234");
    try setField(&msg, 48, "010SUBFIELD1DATA");
    try setField(&msg, 49, "840");
    try setField(&msg, 54, "0020401C000000002000");
    try setField(&msg, 62, "ABCDEF0123456789XYZ");

    var buf1 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf1.deinit();
    try encode(&msg, buf1.writer());

    var msg2 = try Message.init(std.testing.allocator, &VarSpec);
    defer msg2.deinit();
    try msg2.decode(buf1.items);

    var buf2 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf2.deinit();
    try encode(&msg2, buf2.writer());

    try std.testing.expectEqualSlices(u8, buf1.items, buf2.items);
}

test "round-trip BCD MTI" {
    var msg = try Message.init(std.testing.allocator, &BcdMtiSpec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");

    var buf1 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf1.deinit();
    try encode(&msg, buf1.writer());

    // Verify BCD MTI in wire format (first 2 bytes)
    try std.testing.expectEqual(@as(u8, 0x01), buf1.items[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf1.items[1]);

    var msg2 = try Message.init(std.testing.allocator, &BcdMtiSpec);
    defer msg2.deinit();
    try msg2.decode(buf1.items);

    var buf2 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf2.deinit();
    try encode(&msg2, buf2.writer());

    try std.testing.expectEqualSlices(u8, buf1.items, buf2.items);
}

test "round-trip multiple message types" {
    const mtis = [_]struct { u4, mti_mod.MsgClass, mti_mod.MsgFunction, mti_mod.MsgOrigin }{
        .{ 0, .authorization, .request, .acquirer },
        .{ 0, .authorization, .request_response, .acquirer },
        .{ 0, .financial, .request, .acquirer },
        .{ 0, .financial, .request_response, .acquirer },
        .{ 0, .reversal, .request, .acquirer },
        .{ 0, .network_management, .request, .acquirer },
    };

    for (&mtis) |m| {
        var msg = try Message.init(std.testing.allocator, &BasicSpec);
        defer msg.deinit();

        setMti(&msg, m[0], m[1], m[2], m[3]);
        try setField(&msg, 2, "4111111111111111");
        try setField(&msg, 3, "000000");
        try setField(&msg, 4, "000000001000");
        try setField(&msg, 49, "840");

        var buf1 = std.ArrayList(u8).init(std.testing.allocator);
        defer buf1.deinit();
        try encode(&msg, buf1.writer());

        var msg2 = try Message.init(std.testing.allocator, &BasicSpec);
        defer msg2.deinit();
        try msg2.decode(buf1.items);

        try std.testing.expectEqual(m[1], msg2.mti.class);
        try std.testing.expectEqual(m[2], msg2.mti.function);

        var buf2 = std.ArrayList(u8).init(std.testing.allocator);
        defer buf2.deinit();
        try encode(&msg2, buf2.writer());

        try std.testing.expectEqualSlices(u8, buf1.items, buf2.items);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Error Cases
// ═══════════════════════════════════════════════════════════════════════════

test "decode buffer too short for MTI" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    try std.testing.expectError(error.BufferTooShort, msg.decode("01"));
}

test "decode buffer too short for bitmap" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    // MTI (4 bytes) but no bitmap
    try std.testing.expectError(error.BufferTooShort, msg.decode("0100"));
}

test "decode invalid MTI digit" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("XX00"); // Invalid MTI
    try w.writeAll(&[_]u8{0} ** 8); // Bitmap

    try std.testing.expectError(error.InvalidMti, msg.decode(buf.items));
}

test "setField field not in spec" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    // DE5 is not in BasicSpec
    try std.testing.expectError(error.FieldNotInSpec, setField(&msg, 5, "000000001000"));
}

test "setField fixed-length wrong size" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    // DE3 is fixed_6, providing 5 bytes
    try std.testing.expectError(error.InvalidFieldLength, setField(&msg, 3, "00000"));
    // DE3 is fixed_6, providing 7 bytes
    try std.testing.expectError(error.InvalidFieldLength, setField(&msg, 3, "0000000"));
}

test "setField variable-length too long" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    // DE2 max_len = 19, provide 20 chars
    try std.testing.expectError(error.FieldTooLong, setField(&msg, 2, "12345678901234567890"));
}

// ═══════════════════════════════════════════════════════════════════════════
// Message Access Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Message field access after decode" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("0100");
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111");
    try w.writeAll("004000");

    try msg.decode(buf.items);

    // Present fields
    try std.testing.expect(msg.isPresent(2));
    try std.testing.expect(msg.isPresent(3));
    try std.testing.expect(!msg.isPresent(4));
    try std.testing.expect(!msg.isPresent(5));

    // getField returns null for absent
    try std.testing.expectEqual(@as(?[]const u8, null), msg.getField(4));
    try std.testing.expectEqual(@as(?[]const u8, null), msg.getField(5));

    // getFieldInt returns null for absent
    try std.testing.expectEqual(@as(?u64, null), msg.getFieldInt(4));

    // fieldCount
    try std.testing.expectEqual(@as(usize, 2), msg.fieldCount());
}

test "Message fieldIterator" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 49, "840");

    var iter = msg.fieldIterator();
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, 3), iter.next());
    try std.testing.expectEqual(@as(?usize, 49), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "Message.reset clears fields" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try std.testing.expect(msg.isPresent(2));

    msg.reset();
    try std.testing.expect(!msg.isPresent(2));
    try std.testing.expectEqual(@as(usize, 0), msg.fieldCount());
}

// ═══════════════════════════════════════════════════════════════════════════
// Zero-Copy Verification
// ═══════════════════════════════════════════════════════════════════════════

test "zero-copy: field data points into source buffer" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("0100");
    var bm = Bitmap.init();
    bm.set(2);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("164111111111111111");

    const buf_ptr = @intFromPtr(buf.items.ptr);
    try msg.decode(buf.items);

    const pan = msg.getField(2).?;
    // The PAN slice should point within the source buffer
    try std.testing.expect(@intFromPtr(pan.ptr) >= buf_ptr);
    try std.testing.expect(@intFromPtr(pan.ptr) + pan.len <= buf_ptr + buf.items.len);
}

// ═══════════════════════════════════════════════════════════════════════════
// Edge Cases
// ═══════════════════════════════════════════════════════════════════════════

test "decode message with only MTI and no fields" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("0800");
    try w.writeAll(&[_]u8{0} ** 8); // Empty primary bitmap

    try msg.decode(buf.items);
    try std.testing.expectEqual(mti_mod.MsgClass.network_management, msg.mti.class);
    try std.testing.expectEqual(@as(usize, 0), msg.fieldCount());
}

test "decode LLVAR with minimal length (0)" {
    var msg = try Message.init(std.testing.allocator, &VarSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("0200");
    var bm = Bitmap.init();
    bm.set(2);
    bm.set(3);
    bm.set(4);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("00"); // DE2: LLVAR with length 0
    try w.writeAll("000000"); // DE3
    try w.writeAll("000000001000"); // DE4

    try msg.decode(buf.items);
    const pan = msg.getField(2).?;
    try std.testing.expectEqual(@as(usize, 0), pan.len);
}

test "encode/decode PAN with varying lengths" {
    const pans = [_][]const u8{
        "4111111111111111", // 16 digits
        "4111111111111", // 13 digits
        "411111", // 6 digits
        "4", // 1 digit
    };
    for (&pans) |pan| {
        var msg = try Message.init(std.testing.allocator, &BasicSpec);
        defer msg.deinit();

        setMti(&msg, 0, .authorization, .request, .acquirer);
        try setField(&msg, 2, pan);
        try setField(&msg, 3, "000000");
        try setField(&msg, 4, "000000001000");

        var buf1 = std.ArrayList(u8).init(std.testing.allocator);
        defer buf1.deinit();
        try encode(&msg, buf1.writer());

        var msg2 = try Message.init(std.testing.allocator, &BasicSpec);
        defer msg2.deinit();
        try msg2.decode(buf1.items);
        try std.testing.expectEqualSlices(u8, pan, msg2.getField(2).?);
    }
}

test "decode field with all-zeros numeric value" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("0100");
    var bm = Bitmap.init();
    bm.set(3);
    bm.set(4);
    var bm_bytes: [16]u8 = undefined;
    const bm_len = try bm.encode(&bm_bytes);
    try w.writeAll(bm_bytes[0..bm_len]);
    try w.writeAll("000000"); // DE3: all zeros
    try w.writeAll("000000000000"); // DE4: all zeros

    try msg.decode(buf.items);
    try std.testing.expectEqual(@as(?u64, 0), msg.getFieldInt(3));
    try std.testing.expectEqual(@as(?u64, 0), msg.getFieldInt(4));
}

test "decode multiple messages sequentially with reset" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    // Message 1
    var buf1 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf1.deinit();
    {
        const w = buf1.writer();
        try w.writeAll("0100");
        var bm = Bitmap.init();
        bm.set(2);
        var bm_bytes: [16]u8 = undefined;
        const bm_len = try bm.encode(&bm_bytes);
        try w.writeAll(bm_bytes[0..bm_len]);
        try w.writeAll("164111111111111111");
    }

    // Message 2
    var buf2 = std.ArrayList(u8).init(std.testing.allocator);
    defer buf2.deinit();
    {
        const w = buf2.writer();
        try w.writeAll("0200");
        var bm = Bitmap.init();
        bm.set(3);
        var bm_bytes: [16]u8 = undefined;
        const bm_len = try bm.encode(&bm_bytes);
        try w.writeAll(bm_bytes[0..bm_len]);
        try w.writeAll("004000");
    }

    // Decode message 1
    try msg.decode(buf1.items);
    try std.testing.expectEqual(mti_mod.MsgClass.authorization, msg.mti.class);
    try std.testing.expect(msg.isPresent(2));

    // Reset and decode message 2
    msg.reset();
    try msg.decode(buf2.items);
    try std.testing.expectEqual(mti_mod.MsgClass.financial, msg.mti.class);
    try std.testing.expect(!msg.isPresent(2)); // Should be cleared
    try std.testing.expect(msg.isPresent(3));
}

// ═══════════════════════════════════════════════════════════════════════════
// Unknown-field policy (strict decode)
// ═══════════════════════════════════════════════════════════════════════════

const SkipSpec = Spec.define(.{
    .version = .v1987,
    .unknown_fields = .skip, // legacy lenient behavior
    .fields = &.{
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
    },
});

const RejectSpec = Spec.define(.{
    .version = .v1987,
    // .unknown_fields defaults to .reject
    .fields = &.{
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
    },
});

/// Frame with DE4 (in spec) AND DE5 (NOT in spec) set in the bitmap.
fn frameWithUnknownField() [4 + 8 + 12]u8 {
    var frame: [24]u8 = undefined;
    @memcpy(frame[0..4], "0200");
    @memset(frame[4..12], 0);
    frame[4] = 0x18; // bits 4 and 5
    @memcpy(frame[12..24], "000000001000");
    return frame;
}

test "unknown bitmap field: reject is the default and reports the ID" {
    var msg = try Message.init(std.testing.allocator, &RejectSpec);
    defer msg.deinit();

    const frame = frameWithUnknownField();
    try std.testing.expectError(error.FieldNotInSpec, msg.decode(&frame));
    try std.testing.expectEqual(@as(?u8, 5), msg.last_unknown_field);
}

test "unknown bitmap field: skip policy preserves legacy behavior" {
    var msg = try Message.init(std.testing.allocator, &SkipSpec);
    defer msg.deinit();

    const frame = frameWithUnknownField();
    try msg.decode(&frame);
    try std.testing.expectEqual(@as(?u8, 5), msg.last_unknown_field); // still recorded
    try std.testing.expectEqualStrings("000000001000", msg.getField(4).?);
    try std.testing.expect(msg.getField(5) == null);
}

test "clean frame decodes under reject policy" {
    var msg = try Message.init(std.testing.allocator, &RejectSpec);
    defer msg.deinit();

    var frame: [24]u8 = undefined;
    @memcpy(frame[0..4], "0200");
    @memset(frame[4..12], 0);
    frame[4] = 0x10; // bit 4 only
    @memcpy(frame[12..24], "000000001000");

    try msg.decode(&frame);
    try std.testing.expect(msg.last_unknown_field == null);
    try std.testing.expectEqualStrings("000000001000", msg.getField(4).?);
}

// ═══════════════════════════════════════════════════════════════════════════
// setFieldPadded / setFieldInt (response-builder helpers)
// ═══════════════════════════════════════════════════════════════════════════

test "setFieldPadded numeric: right-aligned, zero-padded" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    try setFieldPadded(&msg, 4, "1000"); // DE4 fixed_12
    try std.testing.expectEqualStrings("000000001000", msg.getField(4).?);
    try std.testing.expectEqual(@as(?u64, 1000), msg.getFieldInt(4)); // pre-parsed
}

test "setFieldPadded alpha: left-aligned, space-padded" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    try setFieldPadded(&msg, 41, "T1"); // DE41 fixed_8
    try std.testing.expectEqualStrings("T1      ", msg.getField(41).?);
}

test "setFieldPadded errors" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    try std.testing.expectError(error.InvalidFieldLength, setFieldPadded(&msg, 4, "1234567890123")); // 13 > 12
    try std.testing.expectError(error.NotFixedLength, setFieldPadded(&msg, 2, "4111")); // DE2 is llvar
    try std.testing.expectError(error.FieldNotInSpec, setFieldPadded(&msg, 5, "000000001000")); // not in spec
}

test "setFieldInt: zero-padded numeric" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    try setFieldInt(&msg, 4, 1000);
    try std.testing.expectEqualStrings("000000001000", msg.getField(4).?);
    try setFieldInt(&msg, 11, 42);
    try std.testing.expectEqualStrings("000042", msg.getField(11).?);
}

test "setFieldInt errors" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    try std.testing.expectError(error.NotNumericField, setFieldInt(&msg, 41, 5)); // DE41 is alpha
    try std.testing.expectError(error.Overflow, setFieldInt(&msg, 4, 1000000000000)); // 13 digits > 12
    try std.testing.expectError(error.NotFixedLength, setFieldInt(&msg, 2, 411)); // DE2 is llvar
}

test "padded message round-trips through encode/decode" {
    var msg = try Message.init(std.testing.allocator, &BasicSpec);
    defer msg.deinit();

    setMti(&msg, 0, .financial, .advice_response, .issuer);
    try setFieldPadded(&msg, 4, "150000");
    try setFieldInt(&msg, 11, 7);
    try setFieldPadded(&msg, 41, "TERM002");

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try encode(&msg, buf.writer());

    var got = try Message.init(std.testing.allocator, &BasicSpec);
    defer got.deinit();
    try got.decode(buf.items);

    try std.testing.expectEqualStrings("000000150000", got.getField(4).?);
    try std.testing.expectEqualStrings("000007", got.getField(11).?);
    try std.testing.expectEqualStrings("TERM002 ", got.getField(41).?);
}
