//! Basic example: encode and decode an ISO 8583 message.

const std = @import("std");
const iso8583 = @import("iso8583");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(threaded.io(), &stdout_buf);
    const stdout = &stdout_fw.interface;

    // Use the pre-built v1987 spec
    const spec = &iso8583.SpecV1987;

    // ─── Encode a message ──────────────────────────────────────────────
    try stdout.print("=== Encoding ISO 8583 Message ===\n\n", .{});

    var msg = try iso8583.Message.init(allocator, spec);
    defer msg.deinit();

    iso8583.setMti(&msg, 0, .authorization, .request, .acquirer);
    try iso8583.setField(&msg, 2, "4111111111111111");
    try iso8583.setField(&msg, 3, "000000");
    try iso8583.setField(&msg, 4, "000000001000");
    try iso8583.setField(&msg, 7, "0606123456");
    try iso8583.setField(&msg, 11, "000001");
    try iso8583.setField(&msg, 41, "TERM001 ");
    try iso8583.setField(&msg, 49, "840");

    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try iso8583.encode(&msg, &buf.writer);

    try stdout.print("MTI:     {f}\n", .{msg.mti});
    try stdout.print("Fields:  {d}\n", .{msg.fieldCount()});
    try stdout.print("Wire:    {x} ({d} bytes)\n\n", .{ buf.written(), buf.written().len });

    // ─── Decode the message ─────────────────────────────────────────────
    try stdout.print("=== Decoding ISO 8583 Message ===\n\n", .{});

    var msg2 = try iso8583.Message.init(allocator, spec);
    defer msg2.deinit();
    try msg2.decode(buf.written());

    try stdout.print("MTI:     {f}\n", .{msg2.mti});
    try stdout.print("Version: {d}\n", .{spec.version});
    try stdout.print("Fields:  {d}\n\n", .{msg2.fieldCount()});

    var iter = msg2.fieldIterator();
    while (iter.next()) |field_id| {
        const data = msg2.getField(field_id).?;
        if (msg2.getFieldInt(field_id)) |int_val| {
            try stdout.print("  DE{d:0>3}: {s} ({d})\n", .{ field_id, data, int_val });
        } else {
            try stdout.print("  DE{d:0>3}: {s}\n", .{ field_id, data });
        }
    }

    // ─── Round-trip verification ────────────────────────────────────────
    try stdout.print("\n", .{});
    var buf2 = std.Io.Writer.Allocating.init(allocator);
    defer buf2.deinit();
    try iso8583.encode(&msg2, &buf2.writer);

    if (std.mem.eql(u8, buf.written(), buf2.written())) {
        try stdout.print("✓ Round-trip verified: encode(decode(msg)) == msg\n", .{});
    } else {
        try stdout.print("✗ Round-trip FAILED!\n", .{});
    }

    try stdout.flush();
}
