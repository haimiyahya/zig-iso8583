//! Benchmarks for zig-iso8583.
//!
//! Measures throughput for decode and encode operations.

const std = @import("std");
const iso8583 = @import("iso8583.zig");

const Spec = iso8583.Spec;
const Message = iso8583.Message;
const Bitmap = iso8583.Bitmap;
const encode = iso8583.encode;
const setMti = iso8583.setMti;
const setField = iso8583.setField;

const test_spec = Spec.define(.{
    .version = .v1987,
    .fields = &.{
        iso8583.field.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        iso8583.field.field(3, .fixed_6, .ascii_numeric, .{}),
        iso8583.field.field(4, .fixed_12, .ascii_numeric, .{}),
        iso8583.field.field(7, .fixed_10, .ascii_numeric, .{}),
        iso8583.field.field(11, .fixed_6, .ascii_numeric, .{}),
        iso8583.field.field(41, .fixed_8, .ascii_alpha, .{}),
        iso8583.field.field(49, .fixed_3, .ascii_numeric, .{}),
    },
});

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    // Build a test message buffer
    var msg = try Message.init(allocator, &test_spec);
    defer msg.deinit();

    setMti(&msg, 0, .authorization, .request, .acquirer);
    try setField(&msg, 2, "4111111111111111");
    try setField(&msg, 3, "000000");
    try setField(&msg, 4, "000000001000");
    try setField(&msg, 7, "0606123456");
    try setField(&msg, 11, "000001");
    try setField(&msg, 41, "TERM001 ");
    try setField(&msg, 49, "840");

    var encode_buf = std.Io.Writer.Allocating.init(allocator);
    defer encode_buf.deinit();
    try encode(&msg, &encode_buf.writer);
    const test_data = encode_buf.written();

    try stdout.print("Test message size: {d} bytes\n\n", .{test_data.len});

    const iterations: u64 = 1_000_000;

    // Decode benchmark
    {
        const start = std.Io.Clock.now(.awake, io);
        for (0..iterations) |_| {
            var m = try Message.init(allocator, &test_spec);
            defer m.deinit();
            try m.decode(test_data);
        }
        const end = std.Io.Clock.now(.awake, io);
        const elapsed_ns: f64 = @floatFromInt(end.nanoseconds - start.nanoseconds);
        const per_msg_ns = elapsed_ns / @as(f64, @floatFromInt(iterations));
        const msg_per_sec = 1_000_000_000.0 / per_msg_ns;

        try stdout.print("Decode:   {d:.0} msg/sec  ({d:.1} ns/msg)\n", .{ msg_per_sec, per_msg_ns });
    }

    // Encode benchmark
    {
        const start = std.Io.Clock.now(.awake, io);
        for (0..iterations) |_| {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try encode(&msg, &w);
        }
        const end = std.Io.Clock.now(.awake, io);
        const elapsed_ns: f64 = @floatFromInt(end.nanoseconds - start.nanoseconds);
        const per_msg_ns = elapsed_ns / @as(f64, @floatFromInt(iterations));
        const msg_per_sec = 1_000_000_000.0 / per_msg_ns;

        try stdout.print("Encode:   {d:.0} msg/sec  ({d:.1} ns/msg)\n", .{ msg_per_sec, per_msg_ns });
    }

    // SIMD validation benchmark
    {
        const long_numeric = "1234567890123456789012345678901234567890123456789012345678901234"; // 64 bytes
        const start = std.Io.Clock.now(.awake, io);
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(iso8583.simd.validateAsciiDigits(long_numeric));
        }
        const end = std.Io.Clock.now(.awake, io);
        const elapsed_ns: f64 = @floatFromInt(end.nanoseconds - start.nanoseconds);
        const per_call_ns = elapsed_ns / @as(f64, @floatFromInt(iterations));

        try stdout.print("SIMD validate (64B): {d:.1} ns/call\n", .{per_call_ns});
    }

    // Bitmap count benchmark
    {
        var bm = Bitmap.init();
        bm.set(2);
        bm.set(3);
        bm.set(4);
        bm.set(7);
        bm.set(11);
        bm.set(41);
        bm.set(49);

        const start = std.Io.Clock.now(.awake, io);
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(bm.countPresent());
        }
        const end = std.Io.Clock.now(.awake, io);
        const elapsed_ns: f64 = @floatFromInt(end.nanoseconds - start.nanoseconds);
        const per_call_ns = elapsed_ns / @as(f64, @floatFromInt(iterations));

        try stdout.print("Bitmap count:        {d:.1} ns/call\n", .{per_call_ns});
    }

    try stdout.flush();
}
