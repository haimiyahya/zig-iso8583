//! # Comptime Specification Engine for ISO 8583
//!
//! Provides a DSL to define message specifications at comptime. The spec is
//! used to:
//! - Generate field dispatch tables (no runtime hash maps)
//! - Validate field IDs and types at comptime
//! - Specialize decoder/encoder code per spec
//!
//! ## Defining a Custom Spec
//!
//! ```zig
//! const MySpec = Spec.define(.{
//!     .version = .v1987,
//!     .mti_encoding = .ascii,       // optional, default .ascii
//!     .bitmap_encoding = .binary,   // optional, default .binary
//!     .fields = &.{
//!         field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),  // PAN
//!         field(3, .fixed_6, .ascii_numeric, .{}),               // Processing code
//!         field(4, .fixed_12, .ascii_numeric, .{}),              // Amount
//!         field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }), // Additional data
//!     },
//! });
//! ```
//!
//! ## Pre-built Specs
//!
//! - `SpecV1987` — ISO 8583:1987 with 50+ common financial fields
//! - `SpecV1993` — ISO 8583:1993 updated field set
//! - `SpecV2003` — ISO 8583:2003 with new fields (DE122–DE127)
//!
//! ## Field Lookup
//!
//! `Spec.lookup(id)` resolves a field ID to its descriptor in O(1) using a
//! comptime-built lookup table (`field_index: [129]i16`, -1 = not in spec).
//! No hash maps, no binary search — direct array indexing.

const std = @import("std");
const encoding = @import("encoding.zig");
const field_mod = @import("field.zig");

pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;
pub const FieldDescriptor = field_mod.FieldDescriptor;

// ─── ISO 8583 Version ──────────────────────────────────────────────────────

/// The ISO 8583 standard version a spec targets.
pub const Version = enum {
    /// ISO 8583:1987 — the classic, still most widely used version.
    v1987,
    /// ISO 8583:1993 — minor updates.
    v1993,
    /// ISO 8583:2003 — major revision with new data elements.
    v2003,
};

// ─── Unknown Field Policy ──────────────────────────────────────────────────

/// What to do when a message's bitmap sets a field that the spec does not
/// define. Defaults to `.reject` — for a fixed payment dialect a field
/// outside the spec usually means a misrouted terminal or dialect drift,
/// and decoding "successfully" with fields missing hides the fault.
pub const UnknownFieldPolicy = enum {
    /// Return `error.FieldNotInSpec`; `Message.last_unknown_field` holds the ID.
    reject,
    /// Ignore the field and continue (legacy lenient behavior).
    skip,
};

// ─── MTI Encoding ──────────────────────────────────────────────────────────

/// How the MTI is encoded on the wire.
pub const MtiEncoding = enum {
    /// 4 ASCII bytes: "0100". Human-readable, most common.
    ascii,
    /// 2 BCD bytes: 0x01 0x00. Half the wire size.
    bcd,
};

/// How the bitmap is encoded on the wire.
pub const BitmapEncoding = enum {
    /// 8 or 16 raw bytes. Most common.
    binary,
    /// 16 or 32 ASCII hex digits representing BCD digits (e.g., "7000...").
    bcd,
};

// ─── Spec Definition ───────────────────────────────────────────────────────

/// Configuration for a message specification.
///
/// Passed to `Spec.define()` at comptime. All fields except `fields` and
/// `version` have sensible defaults.
pub const SpecConfig = struct {
    /// ISO 8583 version this spec targets.
    version: Version,
    /// How the MTI is encoded on the wire. Default: .ascii (4 bytes).
    mti_encoding: MtiEncoding = .ascii,
    /// How the bitmap is encoded on the wire. Default: .binary (8/16 bytes).
    bitmap_encoding: BitmapEncoding = .binary,
    /// Field descriptors for all supported data elements.
    fields: []const FieldDescriptor,
    /// Policy for fields present in the bitmap but missing from the spec.
    /// Default: `.reject` (strict — recommended for payment hosts).
    unknown_fields: UnknownFieldPolicy = .reject,
};

/// The compiled specification. All data is comptime-known.
///
/// A `Spec` is an immutable, compile-time constant. The `field_index` lookup
/// table is built at comptime, giving O(1) field resolution at runtime with
/// zero initialization cost.
pub const Spec = struct {
    /// ISO 8583 version this spec targets.
    version: Version,
    /// How the MTI is encoded on the wire.
    mti_encoding: MtiEncoding,
    /// How the bitmap is encoded on the wire.
    bitmap_encoding: BitmapEncoding,
    /// Field descriptors, ordered by field ID.
    fields: []const FieldDescriptor,
    /// Computed lookup table: field_id → index in fields array.
    /// Built at comptime for O(1) field resolution. -1 = not in spec.
    field_index: [129]i16, // 0–128; -1 = not in spec
    /// Policy for bitmap fields not defined in this spec.
    unknown_fields: UnknownFieldPolicy,

    const Self = @This();

    /// Define a spec at comptime.
    ///
    /// Builds the field lookup table and validates the field set at
    /// comptime: out-of-range IDs, duplicate IDs and variable-length
    /// fields without a max_len are **compile errors**, not runtime
    /// surprises. (Previously these were silently ignored/last-wins,
    /// which let dialect bugs ship undetected.)
    ///
    /// ```zig
    /// const MySpec = Spec.define(.{
    ///     .version = .v1987,
    ///     .fields = &.{ field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }) },
    /// });
    /// ```
    pub fn define(comptime config: SpecConfig) Spec {
        comptime validateFields(config.fields);

        comptime var field_index: [129]i16 = .{-1} ** 129;
        comptime for (config.fields, 0..) |desc, i| {
            field_index[desc.id] = @intCast(i);
        };

        return .{
            .version = config.version,
            .mti_encoding = config.mti_encoding,
            .bitmap_encoding = config.bitmap_encoding,
            .fields = config.fields,
            .field_index = field_index,
            .unknown_fields = config.unknown_fields,
        };
    }

    /// Look up a field descriptor by ID. Returns null if not in spec or out of range.
    /// O(1) — direct array indexing into the comptime-built lookup table.
    pub fn lookup(self: Self, field_id: usize) ?FieldDescriptor {
        if (field_id < 2 or field_id > 128) return null;
        const idx = self.field_index[field_id];
        if (idx < 0) return null;
        return self.fields[@intCast(idx)];
    }

    /// Runtime lookup by field ID. Alias for `lookup`.
    pub fn lookupRuntime(self: Self, field_id: usize) ?FieldDescriptor {
        if (field_id < 2 or field_id > 128) return null;
        const idx = self.field_index[field_id];
        if (idx < 0) return null;
        return self.fields[@intCast(idx)];
    }

    /// Check if a field is defined in this spec.
    pub fn hasField(self: Self, field_id: usize) bool {
        return self.lookupRuntime(field_id) != null;
    }

    /// Human-readable field name for logs: the descriptor's `.name` if set,
    /// otherwise null (callers usually fall back to "DE<id>").
    pub fn nameOf(self: Self, field_id: usize) ?[]const u8 {
        const desc = self.lookupRuntime(field_id) orelse return null;
        return desc.name;
    }

    /// Write a human-readable field label to `writer`: the descriptor's
    /// `.name` if set, otherwise "DE<id>". Useful for unambiguous logs:
    ///
    /// ```zig
    /// var buf: [64]u8 = undefined;
    /// var fbs = std.io.fixedBufferStream(&buf);
    /// try spec.writeFieldName(4, fbs.writer());
    /// // fbs.getWritten() == "Amount, transaction" (SpecV1987)
    /// ```
    pub fn writeFieldName(self: Self, field_id: usize, writer: anytype) !void {
        if (self.nameOf(field_id)) |n| {
            try writer.writeAll(n);
        } else {
            try writer.print("DE{d}", .{field_id});
        }
    }

    /// Return the number of fields defined in this spec.
    pub fn fieldCount(self: Self) usize {
        return self.fields.len;
    }

    /// Get MTI wire length in bytes based on encoding (4 for ASCII, 2 for BCD).
    pub fn mtiLen(self: Self) usize {
        return switch (self.mti_encoding) {
            .ascii => 4,
            .bcd => 2,
        };
    }

    /// Get the minimum bitmap byte length (primary only).
    /// 8 bytes for binary encoding, 16 bytes for BCD encoding.
    pub fn bitmapLen(self: Self) usize {
        return switch (self.bitmap_encoding) {
            .binary => 8,
            .bcd => 16,
        };
    }
};

// ─── Comptime Field-Set Validation ─────────────────────────────────────

/// Validate a field set at comptime. Any violation is a compile error:
///
/// - field ID outside 2–128
/// - duplicate field ID
/// - variable-length field without a max_len (would accept any length)
///
/// The checks are factored into `firstInvalidField` so unit tests can
/// exercise the detection logic directly.
pub fn validateFields(comptime fields: []const FieldDescriptor) void {
    comptime {
        @setEvalBranchQuota(100000);
        if (firstInvalidField(fields)) |problem| {
            switch (problem.kind) {
                .id_out_of_range =>
                    @compileError(std.fmt.comptimePrint(
                        "field ID {d} out of range (must be 2-128)", .{problem.id})),
                .duplicate =>
                    @compileError(std.fmt.comptimePrint(
                        "duplicate field ID {d} ({s})", .{ problem.id, problem.name })),
                .missing_max_len =>
                    @compileError(std.fmt.comptimePrint(
                        "variable-length field {d} ({s}) requires opts.max_len", .{ problem.id, problem.name })),
            }
        }
    }
}

/// Description of the first validation problem found in a field set.
pub const FieldProblem = struct {
    pub const Kind = enum { id_out_of_range, duplicate, missing_max_len };
    kind: Kind,
    id: u8,
    name: []const u8,
};

/// Find the first invalid field in a slice of descriptors.
/// Returns null if the field set is valid. Runtime-callable twin of the
/// comptime checks in `validateFields` (unit-testable).
pub fn firstInvalidField(fields: []const FieldDescriptor) ?FieldProblem {
    for (fields, 0..) |desc, i| {
        if (desc.id < 2 or desc.id > 128) {
            return .{ .kind = .id_out_of_range, .id = desc.id, .name = desc.name orelse "?" };
        }
        for (fields[0..i]) |other| {
            if (other.id == desc.id) {
                return .{ .kind = .duplicate, .id = desc.id, .name = desc.name orelse "?" };
            }
        }
        if (desc.length_type.isVariable() and desc.max_len == 0) {
            return .{ .kind = .missing_max_len, .id = desc.id, .name = desc.name orelse "?" };
        }
    }
    return null;
}

// ─── Pre-built Specs ───────────────────────────────────────────────────────

/// ISO 8583:1987 base spec with common financial transaction fields.
pub const SpecV1987 = Spec.define(.{
    .version = .v1987,
    .mti_encoding = .ascii,
    .bitmap_encoding = .binary,
    .fields = &.{
        // Primary account number
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19, .name = "Primary account number" }),
        // Processing code
        field_mod.field(3, .fixed_6, .ascii_numeric, .{ .name = "Processing code" }),
        // Amount, transaction
        field_mod.field(4, .fixed_12, .ascii_numeric, .{ .name = "Amount, transaction" }),
        // Amount, settlement
        field_mod.field(5, .fixed_12, .ascii_numeric, .{ .name = "Amount, settlement" }),
        // Amount, cardholder billing
        field_mod.field(6, .fixed_12, .ascii_numeric, .{ .name = "Amount, cardholder billing" }),
        // Transmission date & time
        field_mod.field(7, .fixed_10, .ascii_numeric, .{ .name = "Transmission date & time" }),
        // Amount, cardholder billing fee
        field_mod.field(8, .fixed_12, .ascii_numeric, .{ .name = "Amount, cardholder billing fee" }),
        // Conversion rate, settlement
        field_mod.field(9, .fixed_8, .ascii_numeric, .{ .name = "Conversion rate, settlement" }),
        // Conversion rate, cardholder billing
        field_mod.field(10, .fixed_8, .ascii_numeric, .{ .name = "Conversion rate, cardholder billing" }),
        // System trace audit number (STAN)
        field_mod.field(11, .fixed_6, .ascii_numeric, .{ .name = "System trace audit number (STAN)" }),
        // Time, local transaction
        field_mod.field(12, .fixed_6, .ascii_numeric, .{ .name = "Time, local transaction" }),
        // Date, local transaction
        field_mod.field(13, .fixed_4, .ascii_numeric, .{ .name = "Date, local transaction" }),
        // Date, expiration
        field_mod.field(14, .fixed_4, .ascii_numeric, .{ .name = "Date, expiration" }),
        // Date, settlement
        field_mod.field(15, .fixed_6, .ascii_numeric, .{ .name = "Date, settlement" }),
        // Date, settlement
        field_mod.field(16, .fixed_4, .ascii_numeric, .{ .name = "Date, settlement" }),
        // Date, capture
        field_mod.field(17, .fixed_4, .ascii_numeric, .{ .name = "Date, capture" }),
        // Merchant type (MCC)
        field_mod.field(18, .fixed_4, .ascii_numeric, .{ .name = "Merchant type (MCC)" }),
        // Acquiring institution country code
        field_mod.field(19, .fixed_3, .ascii_numeric, .{ .name = "Acquiring institution country code" }),
        // PAN extended, country code
        field_mod.field(20, .fixed_3, .ascii_numeric, .{ .name = "PAN extended, country code" }),
        // Transaction life cycle ID
        field_mod.field(22, .fixed_3, .ascii_numeric, .{ .name = "Transaction life cycle ID" }),
        // Card sequence number
        field_mod.field(23, .fixed_3, .ascii_numeric, .{ .name = "Card sequence number" }),
        // Function code
        field_mod.field(24, .fixed_3, .ascii_numeric, .{ .name = "Function code" }),
        // Message reason code
        field_mod.field(25, .fixed_2, .ascii_numeric, .{ .name = "Message reason code" }),
        // Card acceptor business code
        field_mod.field(26, .fixed_2, .ascii_numeric, .{ .name = "Card acceptor business code" }),
        // Receiving institution ID code
        field_mod.field(32, .llvar, .ascii_numeric, .{ .max_len = 11, .name = "Receiving institution ID code" }),
        // Forwarding institution ID code
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11, .name = "Forwarding institution ID code" }),
        // Primary account number, extended
        field_mod.field(34, .llvar, .ascii_numeric, .{ .max_len = 28, .name = "Primary account number, extended" }),
        // Track 2 data
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37, .name = "Track 2 data" }),
        // Track 3 data
        field_mod.field(36, .lllvar, .ascii_alpha, .{ .max_len = 104, .name = "Track 3 data" }),
        // Retrieval reference number
        field_mod.field(37, .fixed_12, .ascii_alpha, .{ .name = "Retrieval reference number" }),
        // Approval code
        field_mod.field(38, .fixed_6, .ascii_alpha, .{ .name = "Approval code" }),
        // Action code
        field_mod.field(39, .fixed_2, .ascii_alpha, .{ .name = "Action code" }),
        // Service code
        field_mod.field(40, .fixed_3, .ascii_numeric, .{ .name = "Service code" }),
        // Card acceptor terminal ID
        field_mod.field(41, .fixed_8, .ascii_alpha, .{ .name = "Card acceptor terminal ID" }),
        // Card acceptor ID code
        field_mod.field(42, .fixed_15, .ascii_alpha, .{ .name = "Card acceptor ID code" }),
        // Card acceptor name/location
        field_mod.field(43, .fixed_40, .ascii_alpha, .{ .name = "Card acceptor name/location" }),
        // Additional response data
        field_mod.field(44, .llvar, .ascii_alpha, .{ .max_len = 99, .name = "Additional response data" }),
        // Track 1 data
        field_mod.field(45, .llvar, .ascii_alpha, .{ .max_len = 76, .name = "Track 1 data" }),
        // Additional data — national
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999, .has_subfields = true, .name = "Additional data — national" }),
        // Currency code, transaction
        field_mod.field(49, .fixed_3, .ascii_numeric, .{ .name = "Currency code, transaction" }),
        // Currency code, settlement
        field_mod.field(50, .fixed_3, .ascii_numeric, .{ .name = "Currency code, settlement" }),
        // PIN data
        field_mod.field(52, .fixed_8, .binary, .{ .name = "PIN data" }),
        // Security related control information
        field_mod.field(53, .fixed_16, .ascii_numeric, .{ .name = "Security related control information" }),
        // Amounts, additional
        field_mod.field(54, .lllvar, .ascii_alpha, .{ .max_len = 120, .name = "Amounts, additional" }),
        // Integrated circuit card (ICC) system related data
        field_mod.field(55, .lllvar, .binary, .{ .max_len = 999, .name = "Integrated circuit card (ICC) system related data" }),
        // Message reason code
        field_mod.field(56, .lllvar, .ascii_alpha, .{ .max_len = 999, .name = "Message reason code" }),
        // Additional data — national
        field_mod.field(59, .lllvar, .ascii_alpha, .{ .max_len = 999, .name = "Additional data — national" }),
        // Reserved national
        field_mod.field(60, .lllvar, .ascii_alpha, .{ .max_len = 999, .name = "Reserved national" }),
        // Reserved national
        field_mod.field(61, .lllvar, .ascii_alpha, .{ .max_len = 999, .name = "Reserved national" }),
        // Additional data — private
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999, .has_subfields = true, .name = "Additional data — private" }),
        // Reserved private
        field_mod.field(63, .lllvar, .ascii_alpha, .{ .max_len = 999, .name = "Reserved private" }),
        // Message authentication code (MAC)
        field_mod.field(64, .fixed_8, .binary, .{ .name = "Message authentication code (MAC)" }),
        // Bit map, tertiary
        field_mod.field(65, .fixed_1, .binary, .{ .name = "Bit map, tertiary" }),
        // Settlement code
        field_mod.field(66, .fixed_1, .ascii_numeric, .{ .name = "Settlement code" }),
        // Network management information code
        field_mod.field(70, .fixed_3, .ascii_numeric, .{ .name = "Network management information code" }),
        // Message number
        field_mod.field(71, .fixed_4, .ascii_numeric, .{ .name = "Message number" }),
        // Data record
        field_mod.field(72, .fixed_4, .ascii_numeric, .{ .name = "Data record" }),
        // Action date
        field_mod.field(73, .fixed_6, .ascii_numeric, .{ .name = "Action date" }),
        // Credits, number
        field_mod.field(75, .fixed_10, .ascii_numeric, .{ .name = "Credits, number" }),
        // Debits, number
        field_mod.field(76, .fixed_10, .ascii_numeric, .{ .name = "Debits, number" }),
        // Credits, reversal number
        field_mod.field(77, .fixed_10, .ascii_numeric, .{ .name = "Credits, reversal number" }),
        // Debits, reversal number
        field_mod.field(78, .fixed_10, .ascii_numeric, .{ .name = "Debits, reversal number" }),
        // Credits, fee number
        field_mod.field(79, .fixed_10, .ascii_numeric, .{ .name = "Credits, fee number" }),
        // Debits, fee number
        field_mod.field(80, .fixed_10, .ascii_numeric, .{ .name = "Debits, fee number" }),
        // Currency code, cardholder billing
        field_mod.field(81, .fixed_3, .ascii_numeric, .{ .name = "Currency code, cardholder billing" }),
        // Currency code, settlement
        field_mod.field(82, .fixed_3, .ascii_numeric, .{ .name = "Currency code, settlement" }),
        // Original data elements
        field_mod.field(90, .fixed_42, .ascii_alpha, .{ .name = "Original data elements" }),
        // File name
        field_mod.field(91, .fixed_1, .ascii_alpha, .{ .name = "File name" }),
        // Transaction destination institution ID
        field_mod.field(100, .llvar, .ascii_numeric, .{ .max_len = 11, .name = "Transaction destination institution ID" }),
        // Transaction originator institution ID
        field_mod.field(101, .llvar, .ascii_alpha, .{ .max_len = 11, .name = "Transaction originator institution ID" }),
        // MAC2
        field_mod.field(128, .fixed_8, .binary, .{ .name = "MAC2" }),
    },
});

/// ISO 8583:1993 spec — extends v1987 with additional fields.
pub const SpecV1993 = Spec.define(.{
    .version = .v1993,
    .mti_encoding = .ascii,
    .bitmap_encoding = .binary,
    .fields = &.{
        // Common fields (same as v1987 for the most part)
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(5, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(6, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
        field_mod.field(9, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(10, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(12, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(13, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(14, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(15, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(18, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(22, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(23, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(25, .fixed_2, .ascii_numeric, .{}),
        field_mod.field(28, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(30, .fixed_24, .ascii_numeric, .{}),
        field_mod.field(32, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37 }),
        field_mod.field(37, .fixed_12, .ascii_alpha, .{}),
        field_mod.field(38, .fixed_6, .ascii_alpha, .{}),
        field_mod.field(39, .fixed_2, .ascii_alpha, .{}),
        field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
        field_mod.field(42, .fixed_15, .ascii_alpha, .{}),
        field_mod.field(43, .fixed_40, .ascii_alpha, .{}),
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(50, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(52, .fixed_8, .binary, .{}),
        field_mod.field(53, .fixed_16, .ascii_numeric, .{}),
        field_mod.field(54, .lllvar, .ascii_alpha, .{ .max_len = 120 }),
        field_mod.field(55, .lllvar, .binary, .{ .max_len = 999 }),
        field_mod.field(61, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(63, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(64, .fixed_8, .binary, .{}),
        field_mod.field(70, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(71, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(72, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(73, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(93, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(94, .fixed_7, .ascii_alpha, .{}),
        field_mod.field(95, .fixed_42, .ascii_alpha, .{}),
        field_mod.field(100, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(101, .llvar, .ascii_alpha, .{ .max_len = 11 }),
        field_mod.field(102, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(103, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(128, .fixed_8, .binary, .{}),
    },
});

/// ISO 8583:2003 spec — updated with new fields and formats.
pub const SpecV2003 = Spec.define(.{
    .version = .v2003,
    .mti_encoding = .ascii,
    .bitmap_encoding = .binary,
    .fields = &.{
        field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
        field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(5, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(6, .fixed_12, .ascii_numeric, .{}),
        field_mod.field(7, .fixed_10, .ascii_numeric, .{}),
        field_mod.field(9, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(10, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(11, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(12, .fixed_6, .ascii_numeric, .{}),
        field_mod.field(13, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(14, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(15, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(18, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(22, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(23, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(25, .fixed_4, .ascii_numeric, .{}),
        field_mod.field(28, .fixed_8, .ascii_numeric, .{}),
        field_mod.field(32, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(33, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(35, .llvar, .ascii_alpha, .{ .max_len = 37 }),
        field_mod.field(37, .fixed_12, .ascii_alpha, .{}),
        field_mod.field(38, .fixed_6, .ascii_alpha, .{}),
        field_mod.field(39, .fixed_2, .ascii_alpha, .{}),
        field_mod.field(41, .fixed_8, .ascii_alpha, .{}),
        field_mod.field(42, .fixed_15, .ascii_alpha, .{}),
        field_mod.field(43, .fixed_40, .ascii_alpha, .{}),
        field_mod.field(48, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(49, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(50, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(52, .fixed_8, .binary, .{}),
        field_mod.field(55, .lllvar, .binary, .{ .max_len = 999 }),
        field_mod.field(62, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(64, .fixed_8, .binary, .{}),
        field_mod.field(70, .fixed_3, .ascii_numeric, .{}),
        field_mod.field(87, .llvar, .ascii_alpha, .{ .max_len = 24 }),
        field_mod.field(88, .llvar, .ascii_alpha, .{ .max_len = 24 }),
        field_mod.field(89, .llvar, .ascii_alpha, .{ .max_len = 17 }),
        field_mod.field(90, .fixed_42, .ascii_alpha, .{}),
        field_mod.field(100, .llvar, .ascii_numeric, .{ .max_len = 11 }),
        field_mod.field(101, .llvar, .ascii_alpha, .{ .max_len = 11 }),
        field_mod.field(102, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(103, .llvar, .ascii_alpha, .{ .max_len = 28 }),
        field_mod.field(122, .llvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(123, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(124, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(125, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(126, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(127, .lllvar, .ascii_alpha, .{ .max_len = 999 }),
        field_mod.field(128, .fixed_8, .binary, .{}),
    },
});

// ─── Tests ─────────────────────────────────────────────────────────────────

test "Spec.define basic" {
    const test_spec = comptime Spec.define(.{
        .version = .v1987,
        .fields = &.{
            field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 }),
            field_mod.field(3, .fixed_6, .ascii_numeric, .{}),
            field_mod.field(4, .fixed_12, .ascii_numeric, .{}),
        },
    });

    try std.testing.expectEqual(Version.v1987, test_spec.version);
    try std.testing.expectEqual(@as(usize, 3), test_spec.fieldCount());
    try std.testing.expect(test_spec.hasField(2));
    try std.testing.expect(test_spec.hasField(3));
    try std.testing.expect(test_spec.hasField(4));
    try std.testing.expect(!test_spec.hasField(5));
}

test "Spec.lookup comptime" {
    const desc = SpecV1987.lookup(2);
    try std.testing.expect(desc != null);
    try std.testing.expectEqual(LengthType.llvar, desc.?.length_type);
    try std.testing.expectEqual(FieldEncoding.ascii_numeric, desc.?.encoding);
    try std.testing.expectEqual(@as(usize, 19), desc.?.max_len);

    const desc3 = SpecV1987.lookup(3);
    try std.testing.expect(desc3 != null);
    try std.testing.expectEqual(LengthType.fixed_6, desc3.?.length_type);
}

test "Spec lookup non-existent field" {
    const desc = SpecV1987.lookup(1);
    try std.testing.expect(desc == null);
}

test "SpecV1987 basic checks" {
    try std.testing.expectEqual(Version.v1987, SpecV1987.version);
    try std.testing.expectEqual(MtiEncoding.ascii, SpecV1987.mti_encoding);
    try std.testing.expectEqual(BitmapEncoding.binary, SpecV1987.bitmap_encoding);
    try std.testing.expect(SpecV1987.hasField(2));
    try std.testing.expect(SpecV1987.hasField(4));
    try std.testing.expect(SpecV1987.hasField(48));
    try std.testing.expect(SpecV1987.hasField(52));
    try std.testing.expect(SpecV1987.hasField(128));
}

test "SpecV1993 basic checks" {
    try std.testing.expectEqual(Version.v1993, SpecV1993.version);
    try std.testing.expect(SpecV1993.hasField(2));
    try std.testing.expect(SpecV1993.hasField(102));
}

test "SpecV2003 basic checks" {
    try std.testing.expectEqual(Version.v2003, SpecV2003.version);
    try std.testing.expect(SpecV2003.hasField(2));
    try std.testing.expect(SpecV2003.hasField(122));
    try std.testing.expect(SpecV2003.hasField(127));
}

test "Spec.mtiLen" {
    const ascii_spec = comptime Spec.define(.{
        .version = .v1987,
        .mti_encoding = .ascii,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 4), ascii_spec.mtiLen());

    const bcd_spec = comptime Spec.define(.{
        .version = .v1987,
        .mti_encoding = .bcd,
        .fields = &.{field_mod.field(2, .llvar, .ascii_numeric, .{ .max_len = 19 })},
    });
    try std.testing.expectEqual(@as(usize, 2), bcd_spec.mtiLen());
}
