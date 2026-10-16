//! # Transport Framing Utilities
//!
//! Wire framing concerns that surround an ISO 8583 message but are not part
//! of it — kept **out of the codec** on purpose: `Message.decode()` always
//! starts at the MTI, and the caller's framer owns everything before it.
//!
//! Two layers exist in classic terminal/switch links (e.g., GHL/MEPS-style
//! hosts):
//!
//! ```text
//! ┌────────────┬──────────────────────┬──────────────────────────────┐
//! │ 2-byte len │  transport header    │  ISO 8583 message (→ decode) │
//! │ (big-end.) │  5B TPDU / 12B ext.  │                              │
//! └────────────┴──────────────────────┴──────────────────────────────┘
//!    framing.zig           framing.zig                codec
//! ```
//!
//! - `stripTransportHeader` / `attachTransportHeader` — remove/prepend the
//!   header bytes around a message payload (5-byte TPDU for terminal links,
//!   12-byte extended header for MEPS Base-24 links, or any custom size).
//! - `LengthPrefix` — the 2-byte big-endian binary length prefix that
//!   delimits frames on the socket.
//!
//! ## Usage
//!
//! ```zig
//! // Inbound: socket frame → payload for the codec
//! const frame = try conn.readFrame();
//! const payload = try framing.stripTransportHeader(frame.body, 5);
//! try msg.decode(payload);
//!
//! // Outbound: encoded message → socket frame
//! var buf = std.Io.Writer.Allocating.init(alloc);
//! defer buf.deinit();
//! const lp = try framing.LengthPrefix.encode(header.len + encoded.len);
//! try buf.writer.writeAll(&lp);
//! try framing.attachTransportHeader(&buf.writer, &header, encoded);
//! ```

const std = @import("std");

// ─── Errors ────────────────────────────────────────────────────────────────

pub const FramingError = error{
    /// Buffer shorter than the requested header/prefix size.
    BufferTooShort,
    /// Payload does not fit in the 2-byte length prefix (> 65535).
    LengthOverflow,
};

// ─── Transport Header ──────────────────────────────────────────────────────

/// Strip a fixed-size transport header (e.g., 5-byte TPDU, 12-byte MEPS
/// Base-24 extended header) and return the ISO 8583 message payload.
///
/// The returned slice aliases `frame` — no copy. The payload is ready for
/// `Message.decode()` (which starts at the MTI).
pub fn stripTransportHeader(frame: []const u8, header_len: usize) FramingError![]const u8 {
    if (frame.len < header_len) return error.BufferTooShort;
    return frame[header_len..];
}

/// Write a transport header followed by the (already encoded) ISO 8583
/// message to `w`.
pub fn attachTransportHeader(w: *std.Io.Writer, header: []const u8, encoded_msg: []const u8) !void {
    try w.writeAll(header);
    try w.writeAll(encoded_msg);
}

// ─── 2-byte Length Prefix ────────────────────────────────────────────────

/// Big-endian 2-byte binary length prefix (classic terminal/switch framing).
pub const LengthPrefix = struct {
    /// Size of the prefix on the wire in bytes.
    pub const BYTES = 2;
    /// Maximum payload length representable (65535).
    pub const MAX_PAYLOAD: usize = (1 << (8 * BYTES)) - 1;

    /// Encode a payload length into its 2-byte wire form.
    /// Returns error.LengthOverflow if `payload_len` > 65535.
    pub fn encode(payload_len: usize) FramingError![BYTES]u8 {
        if (payload_len > MAX_PAYLOAD) return error.LengthOverflow;
        const v: u16 = @intCast(payload_len);
        return .{ @intCast(v >> 8), @intCast(v & 0xFF) };
    }

    /// Decode a 2-byte prefix into the payload length.
    pub fn decode(buf: []const u8) FramingError!usize {
        if (buf.len < BYTES) return error.BufferTooShort;
        return (@as(usize, buf[0]) << 8) | @as(usize, buf[1]);
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "strip transport header (5-byte terminal TPDU)" {
    const header = "TPDU5";
    const msg = "020070380A...";
    var frame: [header.len + msg.len]u8 = undefined;
    @memcpy(frame[0..header.len], header);
    @memcpy(frame[header.len..], msg);

    const payload = try stripTransportHeader(&frame, 5);
    try testing.expectEqualStrings(msg, payload);
}

test "strip transport header (12-byte MEPS B24 ext header)" {
    var frame: [12 + 8]u8 = undefined;
    @memcpy(frame[0..12], "ISO025000070");
    @memcpy(frame[12..], "0210xxxx");
    const payload = try stripTransportHeader(&frame, 12);
    try testing.expectEqualStrings("0210xxxx", payload);
}

test "strip header too short" {
    try testing.expectError(error.BufferTooShort, stripTransportHeader("abc", 5));
}

test "attach transport header" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try attachTransportHeader(&out.writer, "ISO025000070", "0200...");
    try testing.expectEqualStrings("ISO0250000700200...", out.written());
}

test "length prefix round trip" {
    for ([_]usize{ 0, 1, 255, 256, 1024, 65535 }) |n| {
        const enc = try LengthPrefix.encode(n);
        try testing.expectEqual(n, try LengthPrefix.decode(&enc));
    }
}

test "length prefix overflow and short buffer" {
    try testing.expectError(error.LengthOverflow, LengthPrefix.encode(65536));
    try testing.expectError(error.BufferTooShort, LengthPrefix.decode(&.{0x00}));
}
