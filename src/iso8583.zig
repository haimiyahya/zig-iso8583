//! # zig-iso8583 — Core Module
//!
//! This is the root module that re-exports all public types and functions from
//! the library's sub-modules. Import this file to access the full API:
//!
//! ```zig
//! const iso8583 = @import("iso8583");
//! ```
//!
//! ## Re-exported Types
//!
//! | Type | Source | Description |
//! |------|--------|-------------|
//! | `Spec` | `spec` | Comptime message specification |
//! | `Version` | `spec` | ISO 8583 version (v1987, v1993, v2003) |
//! | `MtiEncoding` | `spec` | MTI wire encoding (ASCII or BCD) |
//! | `BitmapEncoding` | `spec` | Bitmap wire encoding (binary or BCD) |
//! | `FieldDescriptor` | `spec` | Field format descriptor |
//! | `FieldEncoding` | `encoding` | How field data is encoded on the wire |
//! | `LengthType` | `encoding` | Fixed or variable-length field type |
//! | `Mti` | `mti` | Parsed Message Type Identifier |
//! | `MsgClass` | `mti` | Message class (authorization, financial, etc.) |
//! | `MsgFunction` | `mti` | Message function (request, response, etc.) |
//! | `MsgOrigin` | `mti` | Message origin (acquirer, issuer, etc.) |
//! | `Bitmap` | `bitmap` | 128-bit presence bitmap |
//! | `FieldStore` | `field` | Zero-copy field storage with direct-index access |
//! | `FieldView` | `field` | Typed view of a decoded field |
//! | `Message` | `decoder` | Decoded ISO 8583 message |
//! | `DecodeError` | `decoder` | Error set for decode operations |
//! | `EncodeError` | `encoder` | Error set for encode operations |
//! | `FieldView2` | `zero_copy` | Alternative field view with asInt()/asBytes() |
//! | `MessageBuffer` | `zero_copy` | Stable backing store for zero-copy views |
//!
//! ## Re-exported Functions
//!
//! | Function | Description |
//! |----------|-------------|
//! | `encode(&msg, writer)` | Serialize a message to any `std.io.Writer` |
//! | `setMti(&msg, ver, class, func, origin)` | Set MTI fields on a message |
//! | `setField(&msg, id, data)` | Set a field's data with validation |
//!
//! ## Pre-built Specifications
//!
//! | Spec | Description |
//! |------|-------------|
//! | `SpecV1987` | ISO 8583:1987 — 50+ common fields |
//! | `SpecV1993` | ISO 8583:1993 — updated field set |
//! | `SpecV2003` | ISO 8583:2003 — new fields and formats |
//!
//! ## Sub-modules (direct access)
//!
//! All sub-modules are also accessible for advanced use:
//!
//! - `iso8583.spec` — Spec DSL and pre-built specs
//! - `iso8583.encoding` — BCD/ASCII codec, length prefix, validation
//! - `iso8583.mti` — MTI types and parse/encode
//! - `iso8583.bitmap` — 128-bit bitmap with SIMD popcount
//! - `iso8583.field` — Field type system, FieldStore
//! - `iso8583.simd` — SIMD-accelerated validation and conversion
//! - `iso8583.decoder` — Zero-copy decode pipeline
//! - `iso8583.encoder` — Encode pipeline
//! - `iso8583.validate` — SIMD field validation, required field rules
//! - `iso8583.zero_copy` — Typed field views, message buffer

const std = @import("std");

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

// ─── Top-level Re-exports ──────────────────────────────────────────────────

// Spec types
pub const Spec = spec.Spec;
pub const Version = spec.Version;
pub const MtiEncoding = spec.MtiEncoding;
pub const BitmapEncoding = spec.BitmapEncoding;
pub const FieldDescriptor = spec.FieldDescriptor;

// Encoding types
pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

// MTI types
pub const Mti = mti.Mti;
pub const MsgClass = mti.MsgClass;
pub const MsgFunction = mti.MsgFunction;
pub const MsgOrigin = mti.MsgOrigin;

// Bitmap types
pub const Bitmap = bitmap.Bitmap;

// Field types
pub const FieldStore = field.FieldStore;
pub const FieldView = field.FieldView;

// Decoder types
pub const Message = decoder.Message;
pub const DecodeError = decoder.DecodeError;

// Encoder types and functions
pub const EncodeError = encoder.EncodeError;
pub const encode = encoder.encode;
pub const setMti = encoder.setMti;
pub const setField = encoder.setField;

// Zero-copy types
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
