//! Comprehensive tests for the MTI module.
//! Covers all message classes, functions, origins, BCD, ASCII, round-trips, edge cases.

const std = @import("std");
const mti = @import("mti.zig");

// ═══════════════════════════════════════════════════════════════════════════
// MsgClass
// ═══════════════════════════════════════════════════════════════════════════

test "MsgClass.fromDigit all valid" {
    try std.testing.expectEqual(mti.MsgClass.authorization, try mti.MsgClass.fromDigit('1'));
    try std.testing.expectEqual(mti.MsgClass.financial, try mti.MsgClass.fromDigit('2'));
    try std.testing.expectEqual(mti.MsgClass.file_actions, try mti.MsgClass.fromDigit('3'));
    try std.testing.expectEqual(mti.MsgClass.reversal, try mti.MsgClass.fromDigit('4'));
    try std.testing.expectEqual(mti.MsgClass.reconciliation, try mti.MsgClass.fromDigit('5'));
    try std.testing.expectEqual(mti.MsgClass.administrative, try mti.MsgClass.fromDigit('6'));
    try std.testing.expectEqual(mti.MsgClass.fee_collection, try mti.MsgClass.fromDigit('7'));
    try std.testing.expectEqual(mti.MsgClass.network_management, try mti.MsgClass.fromDigit('8'));
}

test "MsgClass.fromDigit invalid" {
    // '0' is digit 0, which creates an unnamed enum variant (valid but unnamed)
    // Letters are truly invalid
    try std.testing.expectError(error.InvalidMti, mti.MsgClass.fromDigit('A'));
    try std.testing.expectError(error.InvalidMti, mti.MsgClass.fromDigit('/'));
    try std.testing.expectError(error.InvalidMti, mti.MsgClass.fromDigit(':'));
}

test "MsgClass.toDigit round-trip" {
    try std.testing.expectEqual(@as(u8, '1'), mti.MsgClass.authorization.toDigit());
    try std.testing.expectEqual(@as(u8, '2'), mti.MsgClass.financial.toDigit());
    try std.testing.expectEqual(@as(u8, '8'), mti.MsgClass.network_management.toDigit());
}

// ═══════════════════════════════════════════════════════════════════════════
// MsgFunction
// ═══════════════════════════════════════════════════════════════════════════

test "MsgFunction.fromDigit all valid" {
    try std.testing.expectEqual(mti.MsgFunction.request, try mti.MsgFunction.fromDigit('0'));
    try std.testing.expectEqual(mti.MsgFunction.request_response, try mti.MsgFunction.fromDigit('1'));
    try std.testing.expectEqual(mti.MsgFunction.advice, try mti.MsgFunction.fromDigit('2'));
    try std.testing.expectEqual(mti.MsgFunction.advice_response, try mti.MsgFunction.fromDigit('3'));
    try std.testing.expectEqual(mti.MsgFunction.notification, try mti.MsgFunction.fromDigit('4'));
    try std.testing.expectEqual(mti.MsgFunction.notification_ack, try mti.MsgFunction.fromDigit('5'));
    try std.testing.expectEqual(mti.MsgFunction.instruction, try mti.MsgFunction.fromDigit('6'));
    try std.testing.expectEqual(mti.MsgFunction.instruction_ack, try mti.MsgFunction.fromDigit('7'));
    try std.testing.expectEqual(mti.MsgFunction.positive_ack, try mti.MsgFunction.fromDigit('8'));
    try std.testing.expectEqual(mti.MsgFunction.negative_ack, try mti.MsgFunction.fromDigit('9'));
}

test "MsgFunction.toDigit" {
    try std.testing.expectEqual(@as(u8, '0'), mti.MsgFunction.request.toDigit());
    try std.testing.expectEqual(@as(u8, '1'), mti.MsgFunction.request_response.toDigit());
}

// ═══════════════════════════════════════════════════════════════════════════
// MTI Parse / Encode
// ═══════════════════════════════════════════════════════════════════════════

test "Mti.parse common financial MTIs" {
    // 0100 — Authorization Request
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '1', '0', '0' });
        try std.testing.expectEqual(@as(u4, 0), m.version);
        try std.testing.expectEqual(mti.MsgClass.authorization, m.class);
        try std.testing.expectEqual(mti.MsgFunction.request, m.function);
        try std.testing.expectEqual(mti.MsgOrigin.acquirer, m.origin);
    }
    // 0110 — Authorization Response
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '1', '1', '0' });
        try std.testing.expectEqual(mti.MsgClass.authorization, m.class);
        try std.testing.expectEqual(mti.MsgFunction.request_response, m.function);
    }
    // 0200 — Financial Request
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '2', '0', '0' });
        try std.testing.expectEqual(mti.MsgClass.financial, m.class);
        try std.testing.expectEqual(mti.MsgFunction.request, m.function);
    }
    // 0210 — Financial Response
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '2', '1', '0' });
        try std.testing.expectEqual(mti.MsgClass.financial, m.class);
        try std.testing.expectEqual(mti.MsgFunction.request_response, m.function);
    }
    // 0400 — Reversal Request
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '4', '0', '0' });
        try std.testing.expectEqual(mti.MsgClass.reversal, m.class);
    }
    // 0800 — Network Management Request
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '8', '0', '0' });
        try std.testing.expectEqual(mti.MsgClass.network_management, m.class);
    }
    // 0810 — Network Management Response
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '8', '1', '0' });
        try std.testing.expectEqual(mti.MsgClass.network_management, m.class);
        try std.testing.expectEqual(mti.MsgFunction.request_response, m.function);
    }
}

test "Mti.parse version variants" {
    // Version 0 (1987)
    {
        const m = try mti.Mti.parse(&[_]u8{ '0', '1', '0', '0' });
        try std.testing.expectEqual(@as(u4, 0), m.version);
    }
    // Version 1 (1993)
    {
        const m = try mti.Mti.parse(&[_]u8{ '1', '2', '0', '0' });
        try std.testing.expectEqual(@as(u4, 1), m.version);
        try std.testing.expectEqual(mti.MsgClass.financial, m.class);
    }
}

test "Mti.parse origin/direction" {
    const m0 = try mti.Mti.parse(&[_]u8{ '0', '1', '0', '0' });
    try std.testing.expectEqual(mti.MsgOrigin.acquirer, m0.origin);

    const m2 = try mti.Mti.parse(&[_]u8{ '0', '1', '0', '2' });
    try std.testing.expectEqual(mti.MsgOrigin.issuer, m2.origin);

    const m4 = try mti.Mti.parse(&[_]u8{ '0', '1', '0', '4' });
    try std.testing.expectEqual(mti.MsgOrigin.other, m4.origin);
}

test "Mti.parse invalid digit" {
    try std.testing.expectError(error.InvalidMti, mti.Mti.parse(&[_]u8{ 'A', '1', '0', '0' }));
    try std.testing.expectError(error.InvalidMti, mti.Mti.parse(&[_]u8{ '0', '1', '0', ' ' }));
}

// ═══════════════════════════════════════════════════════════════════════════
// BCD Encode/Decode
// ═══════════════════════════════════════════════════════════════════════════

test "Mti.parseBcd common MTIs" {
    // 0x01 0x00 → "0100" → Authorization Request
    {
        const m = try mti.Mti.parseBcd(&[_]u8{ 0x01, 0x00 });
        try std.testing.expectEqual(mti.MsgClass.authorization, m.class);
        try std.testing.expectEqual(mti.MsgFunction.request, m.function);
    }
    // 0x02 0x00 → "0200" → Financial Request
    {
        const m = try mti.Mti.parseBcd(&[_]u8{ 0x02, 0x00 });
        try std.testing.expectEqual(mti.MsgClass.financial, m.class);
    }
    // 0x04 0x00 → "0400" → Reversal
    {
        const m = try mti.Mti.parseBcd(&[_]u8{ 0x04, 0x00 });
        try std.testing.expectEqual(mti.MsgClass.reversal, m.class);
    }
    // 0x08 0x00 → "0800" → Network Management
    {
        const m = try mti.Mti.parseBcd(&[_]u8{ 0x08, 0x00 });
        try std.testing.expectEqual(mti.MsgClass.network_management, m.class);
    }
}

test "Mti.toBcd" {
    const m = mti.Mti{ .version = 0, .class = .authorization, .function = .request, .origin = .acquirer };
    const bcd = try m.toBcd();
    try std.testing.expectEqual(@as(u8, 0x01), bcd[0]);
    try std.testing.expectEqual(@as(u8, 0x00), bcd[1]);
}

// ═══════════════════════════════════════════════════════════════════════════
// Round-trips
// ═══════════════════════════════════════════════════════════════════════════

test "Mti ASCII round-trip for all common MTIs" {
    const mtis = [_][4]u8{
        [_]u8{ '0', '1', '0', '0' },
        [_]u8{ '0', '1', '1', '0' },
        [_]u8{ '0', '2', '0', '0' },
        [_]u8{ '0', '2', '1', '0' },
        [_]u8{ '0', '4', '0', '0' },
        [_]u8{ '0', '4', '2', '0' },
        [_]u8{ '0', '8', '0', '0' },
        [_]u8{ '0', '8', '1', '0' },
    };
    for (&mtis) |expected| {
        const parsed = try mti.Mti.parse(&expected);
        const result = parsed.toAscii();
        try std.testing.expectEqualSlices(u8, &expected, &result);
    }
}

test "Mti BCD round-trip" {
    const bcd_mtis = [_][2]u8{
        [_]u8{ 0x01, 0x00 },
        [_]u8{ 0x02, 0x00 },
        [_]u8{ 0x08, 0x00 },
        [_]u8{ 0x01, 0x10 },
        [_]u8{ 0x04, 0x20 },
    };
    for (&bcd_mtis) |expected| {
        const parsed = try mti.Mti.parseBcd(&expected);
        const result = try parsed.toBcd();
        try std.testing.expectEqualSlices(u8, &expected, &result);
    }
}

test "Mti ASCII ↔ BCD cross-format round-trip" {
    // Parse ASCII → toBcd → parseBcd → toAscii should match original
    const original = &[_]u8{ '0', '2', '0', '0' };
    const parsed = try mti.Mti.parse(original);
    const bcd = try parsed.toBcd();
    const reparsed = try mti.Mti.parseBcd(&bcd);
    const result = reparsed.toAscii();
    try std.testing.expectEqualSlices(u8, original, &result);
}

// ═══════════════════════════════════════════════════════════════════════════
// Mti.value() and format()
// ═══════════════════════════════════════════════════════════════════════════

test "Mti.value" {
    try std.testing.expectEqual(@as(u16, 100), (try mti.Mti.parse(&[_]u8{ '0', '1', '0', '0' })).value());
    try std.testing.expectEqual(@as(u16, 200), (try mti.Mti.parse(&[_]u8{ '0', '2', '0', '0' })).value());
    try std.testing.expectEqual(@as(u16, 210), (try mti.Mti.parse(&[_]u8{ '0', '2', '1', '0' })).value());
    try std.testing.expectEqual(@as(u16, 420), (try mti.Mti.parse(&[_]u8{ '0', '4', '2', '0' })).value());
    try std.testing.expectEqual(@as(u16, 800), (try mti.Mti.parse(&[_]u8{ '0', '8', '0', '0' })).value());
    try std.testing.expectEqual(@as(u16, 1200), (try mti.Mti.parse(&[_]u8{ '1', '2', '0', '0' })).value());
}

test "Mti.format" {
    const m = try mti.Mti.parse(&[_]u8{ '0', '4', '2', '0' });
    var buf: [4]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{m});
    try std.testing.expectEqualSlices(u8, "0420", w.buffered());
}
