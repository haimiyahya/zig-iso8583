//! # ISO 8583 Message Type Identifier (MTI)
//!
//! The MTI is a 4-digit number that identifies the purpose and origin of
//! an ISO 8583 message. It is structured as:
//!
//! ```
//!   Digit 1: Version/Variant (0=1987, 1=1993, 2=2003)
//!   Digit 2: Message Class (1=Authorization, 2=Financial, ...)
//!   Digit 3: Message Function (0=Request, 1=Response, 2=Advice, ...)
//!   Digit 4: Message Origin (0=Acquirer, 2=Issuer, 4=Other, ...)
//! ```
//!
//! ## Common MTIs
//!
//! | MTI  | Class          | Function | Description                    |
//! |------|----------------|----------|--------------------------------|
//! | 0100 | Authorization  | Request  | Auth request from acquirer     |
//! | 0110 | Authorization  | Response | Auth response from issuer      |
//! | 0200 | Financial      | Request  | Financial request              |
//! | 0210 | Financial      | Response | Financial response             |
//! | 0400 | Reversal       | Request  | Reversal request               |
//! | 0420 | Reversal       | Advice   | Reversal advice                |
//! | 0800 | Network Mgmt   | Request  | Sign-on, echo test, etc.       |
//! | 0810 | Network Mgmt   | Response | Network management response    |
//!
//! ## Wire Encoding
//!
//! The MTI can be encoded as either 4 ASCII bytes ("0200") or 2 BCD bytes
//! (0x02 0x00), controlled by `Spec.mti_encoding`.
//!
//! ## Usage
//!
//! ```zig
//! // Parse from ASCII
//! const mti = try Mti.parse(&[_]u8{ '0', '1', '0', '0' });
//! // mti.version == 0, mti.class == .authorization
//! // mti.function == .request, mti.origin == .acquirer
//!
//! // Parse from BCD
//! const mti = try Mti.parseBcd(&[_]u8{ 0x02, 0x00 });
//!
//! // Encode back
//! const ascii = mti.toAscii(); // → [4]u8{ '0', '2', '0', '0' }
//! const bcd = try mti.toBcd(); // → [2]u8{ 0x02, 0x00 }
//! ```

const std = @import("std");
const encoding = @import("encoding.zig");

/// Message Class (digit 2 of MTI).
pub const MsgClass = enum(u4) {
    authorization = 0x1,
    financial = 0x2,
    file_actions = 0x3,
    reversal = 0x4,
    reconciliation = 0x5,
    administrative = 0x6,
    fee_collection = 0x7,
    network_management = 0x8,
    _,

    /// Parse from an ASCII digit byte. Returns error.InvalidMti if not '0'–'9'.
    pub fn fromDigit(d: u8) !MsgClass {
        if (d < 0x30 or d > 0x39) return error.InvalidMti;
        return @enumFromInt(d - 0x30);
    }

    /// Encode as an ASCII digit byte.
    pub fn toDigit(self: MsgClass) u8 {
        return @as(u8, @intFromEnum(self)) + 0x30;
    }
};

/// Message Function (digit 3 of MTI).
pub const MsgFunction = enum(u4) {
    request = 0x0,
    request_response = 0x1,
    advice = 0x2,
    advice_response = 0x3,
    notification = 0x4,
    notification_ack = 0x5,
    instruction = 0x6,
    instruction_ack = 0x7,
    positive_ack = 0x8,
    negative_ack = 0x9,
    _,

    pub fn fromDigit(d: u8) !MsgFunction {
        if (d < 0x30 or d > 0x39) return error.InvalidMti;
        return @enumFromInt(d - 0x30);
    }

    pub fn toDigit(self: MsgFunction) u8 {
        return @as(u8, @intFromEnum(self)) + 0x30;
    }
};

/// Message Origin (digit 4 of MTI).
pub const MsgOrigin = enum(u4) {
    acquirer = 0x0,
    acquirer_repeat = 0x1,
    issuer = 0x2,
    issuer_repeat = 0x3,
    other = 0x4,
    other_repeat = 0x5,
    _,

    pub fn fromDigit(d: u8) !MsgOrigin {
        if (d < 0x30 or d > 0x39) return error.InvalidMti;
        return @enumFromInt(d - 0x30);
    }

    pub fn toDigit(self: MsgOrigin) u8 {
        return @as(u8, @intFromEnum(self)) + 0x30;
    }
};

/// Parsed MTI structure.
///
/// Fields correspond to the 4 digits of the MTI:
/// - `version`: ISO 8583 variant (0=1987, 1=1993, 2=2003)
/// - `class`: Message class (authorization, financial, etc.)
/// - `function`: Message function (request, response, advice, etc.)
/// - `origin`: Originator (acquirer, issuer, other, etc.)
pub const Mti = packed struct {
    version: u4,
    class: MsgClass,
    function: MsgFunction,
    origin: MsgOrigin,

    const Self = @This();

    /// Parse an MTI from 4 ASCII digit bytes.
    /// Returns error.InvalidMti if any byte is not '0'–'9'.
    pub fn parse(buf: *const [4]u8) !Mti {
        for (buf) |b| {
            if (b < 0x30 or b > 0x39) return error.InvalidMti;
        }
        return .{
            .version = @intCast(buf[0] - 0x30),
            .class = try MsgClass.fromDigit(buf[1]),
            .function = try MsgFunction.fromDigit(buf[2]),
            .origin = try MsgOrigin.fromDigit(buf[3]),
        };
    }

    /// Parse an MTI from a 2-byte BCD representation.
    /// Example: 0x01 0x00 → "0100" (Authorization Request)
    pub fn parseBcd(buf: *const [2]u8) !Mti {
        var ascii: [4]u8 = undefined;
        encoding.bcdToAscii(buf, &ascii);
        return parse(&ascii);
    }

    /// Encode the MTI as 4 ASCII digit bytes.
    pub fn toAscii(self: Self) [4]u8 {
        return .{
            @as(u8, self.version) + 0x30,
            self.class.toDigit(),
            self.function.toDigit(),
            self.origin.toDigit(),
        };
    }

    /// Encode the MTI as 2 BCD bytes.
    pub fn toBcd(self: Self) ![2]u8 {
        const ascii = self.toAscii();
        var bcd: [2]u8 = undefined;
        try encoding.asciiToBcd(&ascii, &bcd);
        return bcd;
    }

    /// Return the 4-digit decimal value (e.g., 0100 → 100, 0210 → 210).
    pub fn value(self: Self) u16 {
        const v: u16 = @intCast(self.version);
        const c: u16 = @intFromEnum(self.class);
        const f: u16 = @intFromEnum(self.function);
        const o: u16 = @intFromEnum(self.origin);
        return v * 1000 + c * 100 + f * 10 + o;
    }

    /// Format the MTI as a 4-digit string for std.fmt (`{f}`).
    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const ascii = self.toAscii();
        try w.writeAll(&ascii);
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

test "Mti.parse ASCII" {
    const mti = try Mti.parse(&[_]u8{ '0', '1', '0', '0' });
    try std.testing.expectEqual(@as(u4, 0), mti.version);
    try std.testing.expectEqual(MsgClass.authorization, mti.class);
    try std.testing.expectEqual(MsgFunction.request, mti.function);
    try std.testing.expectEqual(MsgOrigin.acquirer, mti.origin);
}

test "Mti.parse BCD" {
    const mti = try Mti.parseBcd(&[_]u8{ 0x01, 0x00 });
    try std.testing.expectEqual(@as(u4, 0), mti.version);
    try std.testing.expectEqual(MsgClass.authorization, mti.class);
}

test "Mti.toAscii" {
    const mti = Mti{ .version = 0, .class = .financial, .function = .request, .origin = .acquirer };
    try std.testing.expectEqualSlices(u8, "0200", &mti.toAscii());
}

test "Mti.toBcd" {
    const mti = Mti{ .version = 0, .class = .authorization, .function = .request, .origin = .acquirer };
    const bcd = try mti.toBcd();
    try std.testing.expectEqual(@as(u8, 0x01), bcd[0]);
    try std.testing.expectEqual(@as(u8, 0x00), bcd[1]);
}

test "Mti round-trip" {
    const original = &[_]u8{ '0', '8', '0', '0' };
    const mti = try Mti.parse(original);
    const result = mti.toAscii();
    try std.testing.expectEqualSlices(u8, original, &result);
}

test "Mti.value" {
    const mti = try Mti.parse(&[_]u8{ '0', '1', '0', '0' });
    try std.testing.expectEqual(@as(u16, 100), mti.value());
}

test "Mti.format" {
    const mti = try Mti.parse(&[_]u8{ '0', '4', '2', '0' });
    var buf: [4]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{mti});
    try std.testing.expectEqualSlices(u8, "0420", w.buffered());
}
