//! zig-iso8583 — High-performance ISO 8583 parser/serializer in Zig
//!
//! Features:
//! - Zero-copy decode: fields are slices into the source buffer
//! - SIMD-accelerated: bitmap scan, ASCII validation, BCD conversion
//! - ArenaAllocator: per-message arena, bulk deallocation
//! - Comptime spec DSL: monomorphized field dispatch, version branch elimination
//!
//! Quick start:
//! ```zig
//! const iso8583 = @import("iso8583");
//!
//! // Use a pre-built spec or define your own at comptime
//! const MySpec = comptime iso8583.Spec.define(.{
//!     .version = .v1987,
//!     .fields = &.{
//!         iso8583.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
//!         iso8583.field(3, .fixed_6, .ascii_numeric, .{}),
//!         iso8583.field(4, .fixed_12, .ascii_numeric, .{}),
//!     },
//! });
//!
//! // Decode
//! var msg = try iso8583.Message.init(allocator, &MySpec);
//! defer msg.deinit();
//! try msg.decode(raw_bytes);
//! const pan = msg.getField(2); // → []const u8 (zero-copy)
//!
//! // Encode
//! var buf = std.ArrayList(u8).init(allocator);
//! try iso8583.encode(&msg, buf.writer());
//! ```

pub const spec = @import("spec.zig");
pub const encoding = @import("encoding.zig");
pub const mti = @import("mti.zig");
pub const bitmap = @import("bitmap.zig");
pub const field = @import("field.zig");
pub const simd = @import("simd.zig");
pub const decoder = @import("decoder.zig");
pub const encoder = @import("encoder.zig");
pub const validate = @import("validate.zig");
pub const zero_copy = @import("zero_copy.zig");

// Re-export main types at top level for convenience
pub const Spec = spec.Spec;
pub const Version = spec.Version;
pub const MtiEncoding = spec.MtiEncoding;
pub const BitmapEncoding = spec.BitmapEncoding;
pub const FieldDescriptor = spec.FieldDescriptor;

pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

pub const Mti = mti.Mti;
pub const MsgClass = mti.MsgClass;
pub const MsgFunction = mti.MsgFunction;
pub const MsgOrigin = mti.MsgOrigin;

pub const Bitmap = bitmap.Bitmap;

pub const FieldStore = field.FieldStore;
pub const FieldView = field.FieldView;

pub const Message = decoder.Message;
pub const DecodeError = decoder.DecodeError;

pub const EncodeError = encoder.EncodeError;
pub const encode = encoder.encode;
pub const setMti = encoder.setMti;
pub const setField = encoder.setField;

pub const FieldView2 = zero_copy.FieldView;
pub const MessageBuffer = zero_copy.MessageBuffer;

// Pre-built specs
pub const SpecV1987 = spec.SpecV1987;
pub const SpecV1993 = spec.SpecV1993;
pub const SpecV2003 = spec.SpecV2003;

// ─── Tests ─────────────────────────────────────────────────────────────────

test {
    // Run all sub-module tests
    @import("std").testing.refAllDeclsRecursive(@This());
}
