//! Comprehensive tests for the bitmap module.
//! Covers all 128 bits, primary/secondary, encode/decode, iteration, edge cases.

const std = @import("std");
const bitmap_mod = @import("bitmap.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Initialization
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.init is all zero" {
    const bm = bitmap_mod.Bitmap.init();
    for (1..129) |fid| {
        try std.testing.expect(!bm.isPresent(fid));
    }
    try std.testing.expectEqual(@as(u32, 0), bm.countPresent());
}

// ═══════════════════════════════════════════════════════════════════════════
// Set / IsPresent / Unset — individual fields
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap set/isPresent all primary fields (2–64)" {
    var bm = bitmap_mod.Bitmap.init();
    for (2..65) |fid| {
        bm.set(fid);
        try std.testing.expect(bm.isPresent(fid));
    }
    try std.testing.expectEqual(@as(u32, 63), bm.countPresent());
}

test "Bitmap set/isPresent all secondary fields (65–128)" {
    var bm = bitmap_mod.Bitmap.init();
    for (65..129) |fid| {
        bm.set(fid);
        try std.testing.expect(bm.isPresent(fid));
    }
    try std.testing.expectEqual(@as(u32, 64), bm.countPresent());
}

test "Bitmap set/unset" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(7);
    try std.testing.expect(bm.isPresent(7));
    bm.unset(7);
    try std.testing.expect(!bm.isPresent(7));
}

test "Bitmap unset non-present field is no-op" {
    var bm = bitmap_mod.Bitmap.init();
    bm.unset(10); // Not set, should be safe
    try std.testing.expect(!bm.isPresent(10));
}

test "Bitmap out-of-range fields" {
    var bm = bitmap_mod.Bitmap.init();
    // Field 0 doesn't exist
    bm.set(0);
    try std.testing.expect(!bm.isPresent(0));
    // Field 129 is out of range
    bm.set(129);
    try std.testing.expect(!bm.isPresent(129));
    // isPresent for out of range
    try std.testing.expect(!bm.isPresent(0));
    try std.testing.expect(!bm.isPresent(129));
    try std.testing.expect(!bm.isPresent(200));
}

// ═══════════════════════════════════════════════════════════════════════════
// Boundary fields (edges of bytes)
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap byte boundary fields" {
    // Fields at byte boundaries: 1,8 (byte 0); 9,16 (byte 1); etc.
    var bm = bitmap_mod.Bitmap.init();
    const boundary_fields = [_]usize{ 1, 8, 9, 16, 17, 24, 25, 32, 33, 40, 41, 48, 49, 56, 57, 64, 65, 72, 73, 80, 81, 88, 89, 96, 97, 104, 105, 112, 113, 120, 121, 128 };
    for (&boundary_fields) |fid| {
        bm.set(fid);
    }
    for (&boundary_fields) |fid| {
        try std.testing.expect(bm.isPresent(fid));
    }
    try std.testing.expectEqual(@as(u32, boundary_fields.len), bm.countPresent());
}

// ═══════════════════════════════════════════════════════════════════════════
// Parse
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.parse primary only — various fields" {
    // Fields 3, 7, 11
    var bm = bitmap_mod.Bitmap.init();
    bm.set(3);
    bm.set(7);
    bm.set(11);
    var wire: [16]u8 = undefined;
    const len = try bm.encode(&wire);
    try std.testing.expectEqual(@as(usize, 8), len);

    const result = try bitmap_mod.Bitmap.parse(wire[0..len]);
    try std.testing.expect(result.bitmap.isPresent(3));
    try std.testing.expect(result.bitmap.isPresent(7));
    try std.testing.expect(result.bitmap.isPresent(11));
    try std.testing.expect(!result.bitmap.isPresent(2));
    try std.testing.expect(!result.bitmap.isPresent(65));
    try std.testing.expectEqual(@as(usize, 8), result.consumed);
}

test "Bitmap.parse with secondary bitmap" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(2);
    bm.set(65);
    bm.set(128);
    var wire: [16]u8 = undefined;
    const len = try bm.encode(&wire);
    try std.testing.expectEqual(@as(usize, 16), len);

    const result = try bitmap_mod.Bitmap.parse(wire[0..len]);
    try std.testing.expect(result.bitmap.isPresent(1)); // bit 1 = secondary indicator
    try std.testing.expect(result.bitmap.isPresent(2));
    try std.testing.expect(result.bitmap.isPresent(65));
    try std.testing.expect(result.bitmap.isPresent(128));
    try std.testing.expectEqual(@as(usize, 16), result.consumed);
}

test "Bitmap.parse empty primary (no fields)" {
    const buf = [_]u8{0} ** 8;
    const result = try bitmap_mod.Bitmap.parse(&buf);
    for (1..65) |fid| {
        try std.testing.expect(!result.bitmap.isPresent(fid));
    }
}

test "Bitmap.parse all fields set" {
    var bm = bitmap_mod.Bitmap.init();
    for (2..129) |fid| bm.set(fid);
    var wire: [16]u8 = undefined;
    const len = try bm.encode(&wire);

    const result = try bitmap_mod.Bitmap.parse(wire[0..len]);
    for (2..129) |fid| {
        try std.testing.expect(result.bitmap.isPresent(fid));
    }
}

test "Bitmap.parse buffer too short — primary" {
    const buf = [_]u8{0} ** 7;
    try std.testing.expectError(error.BufferTooShort, bitmap_mod.Bitmap.parse(&buf));
}

test "Bitmap.parse buffer too short — needs secondary" {
    var buf: [12]u8 = .{0} ** 12;
    buf[0] = 0x80; // bit 1 set → needs secondary
    try std.testing.expectError(error.BufferTooShort, bitmap_mod.Bitmap.parse(&buf));
}

// ═══════════════════════════════════════════════════════════════════════════
// Encode
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.encode primary only returns 8 bytes" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(4);
    var out: [16]u8 = undefined;
    const len = try bm.encode(&out);
    try std.testing.expectEqual(@as(usize, 8), len);
    // Bit 1 should NOT be set
    try std.testing.expect((out[0] & 0x80) == 0);
}

test "Bitmap.encode with secondary returns 16 bytes and sets bit 1" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(2);
    bm.set(70);
    var out: [16]u8 = undefined;
    const len = try bm.encode(&out);
    try std.testing.expectEqual(@as(usize, 16), len);
    // Bit 1 should be set
    try std.testing.expect((out[0] & 0x80) != 0);
}

test "Bitmap.encode out buffer too small" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(2);
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooShort, bm.encode(&out));
}

// ═══════════════════════════════════════════════════════════════════════════
// Round-trip
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap encode/parse round-trip — scattered fields" {
    var bm = bitmap_mod.Bitmap.init();
    const fields = [_]usize{ 2, 3, 4, 7, 11, 12, 22, 23, 35, 41, 48, 49, 52, 55, 62, 64 };
    for (&fields) |fid| bm.set(fid);

    var wire: [16]u8 = undefined;
    const len = try bm.encode(&wire);
    const result = try bitmap_mod.Bitmap.parse(wire[0..len]);

    for (&fields) |fid| {
        try std.testing.expect(result.bitmap.isPresent(fid));
    }
    // Check some absent fields
    try std.testing.expect(!result.bitmap.isPresent(5));
    try std.testing.expect(!result.bitmap.isPresent(100));
}

test "Bitmap encode/parse round-trip — secondary fields" {
    var bm = bitmap_mod.Bitmap.init();
    const fields = [_]usize{ 2, 65, 70, 100, 128 };
    for (&fields) |fid| bm.set(fid);

    var wire: [16]u8 = undefined;
    const len = try bm.encode(&wire);
    const result = try bitmap_mod.Bitmap.parse(wire[0..len]);

    for (&fields) |fid| {
        try std.testing.expect(result.bitmap.isPresent(fid));
    }
}

test "Bitmap encode/parse round-trip — every single field" {
    for (2..129) |target_fid| {
        var bm = bitmap_mod.Bitmap.init();
        bm.set(target_fid);
        var wire: [16]u8 = undefined;
        const len = try bm.encode(&wire);
        const result = try bitmap_mod.Bitmap.parse(wire[0..len]);
        try std.testing.expect(result.bitmap.isPresent(target_fid));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// needsSecondary
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.needsSecondary" {
    // Primary only
    {
        var bm = bitmap_mod.Bitmap.init();
        bm.set(2);
        bm.set(64);
        try std.testing.expect(!bm.needsSecondary());
    }
    // Secondary needed
    {
        var bm = bitmap_mod.Bitmap.init();
        bm.set(65);
        try std.testing.expect(bm.needsSecondary());
    }
    {
        var bm = bitmap_mod.Bitmap.init();
        bm.set(128);
        try std.testing.expect(bm.needsSecondary());
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// countPresent
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.countPresent" {
    // 0
    {
        const bm = bitmap_mod.Bitmap.init();
        try std.testing.expectEqual(@as(u32, 0), bm.countPresent());
    }
    // 1
    {
        var bm = bitmap_mod.Bitmap.init();
        bm.set(7);
        try std.testing.expectEqual(@as(u32, 1), bm.countPresent());
    }
    // Multiple
    {
        var bm = bitmap_mod.Bitmap.init();
        bm.set(2);
        bm.set(4);
        bm.set(7);
        bm.set(11);
        bm.set(48);
        bm.set(65);
        bm.set(100);
        try std.testing.expectEqual(@as(u32, 7), bm.countPresent());
    }
    // All
    {
        var bm = bitmap_mod.Bitmap.init();
        for (2..129) |fid| bm.set(fid);
        try std.testing.expectEqual(@as(u32, 127), bm.countPresent());
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Iterator
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.iterator empty" {
    const bm = bitmap_mod.Bitmap.init();
    var iter = bm.iterator();
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "Bitmap.iterator single field" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(7);
    var iter = bm.iterator();
    try std.testing.expectEqual(@as(?usize, 7), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "Bitmap.iterator multiple fields in order" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(7);
    bm.set(2);
    bm.set(48);
    bm.set(11);
    bm.set(65);
    var iter = bm.iterator();
    // Should iterate in ascending order
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, 7), iter.next());
    try std.testing.expectEqual(@as(?usize, 11), iter.next());
    try std.testing.expectEqual(@as(?usize, 48), iter.next());
    try std.testing.expectEqual(@as(?usize, 65), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "Bitmap.iterator skips field 1 (bitmap indicator)" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(1); // Bitmap indicator — iterator should skip
    bm.set(2);
    var iter = bm.iterator();
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

// ═══════════════════════════════════════════════════════════════════════════
// presenceArray
// ═══════════════════════════════════════════════════════════════════════════

test "Bitmap.presenceArray" {
    var bm = bitmap_mod.Bitmap.init();
    bm.set(2);
    bm.set(4);
    bm.set(65);
    const arr = bm.presenceArray();
    try std.testing.expect(arr[1]); // field 2 → index 1
    try std.testing.expect(arr[3]); // field 4 → index 3
    try std.testing.expect(arr[64]); // field 65 → index 64
    try std.testing.expect(!arr[0]); // field 1
    try std.testing.expect(!arr[2]); // field 3
}
