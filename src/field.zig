//! # Field Type System for ISO 8583 Data Elements
//!
//! Provides the field descriptor (comptime), field view (zero-copy runtime),
//! and field store (direct-index storage with no hash maps).
//!
//! ## FieldDescriptor
//!
//! Describes a single data element's format. Created at comptime via
//! `field()` helper and used to build `Spec` definitions.
//!
//! ## FieldView
//!
//! A decoded field: a typed view into the source message buffer.
//! `raw` points into the original buffer — zero copy.
//!
//! ## FieldStore
//!
//! Stores decoded field data using a flat array indexed by (field_id - 2).
//! Uses a `std.StaticBitSet` for presence tracking and direct-index access
//! for O(1) field lookup — no hash maps.

const std = @import("std");
const encoding = @import("encoding.zig");
const bitmap = @import("bitmap.zig");

pub const FieldEncoding = encoding.FieldEncoding;
pub const LengthType = encoding.LengthType;

// ─── Field Descriptor (comptime) ────────────────────────────────────────────

/// Describes a single data element's format. Used at comptime to build specs.
///
/// Created via the `field()` helper. `max_len` is derived automatically for
/// fixed-length fields; for variable-length fields it comes from `opts`.
pub const FieldDescriptor = struct {
    /// Field ID (2–128).
    id: u8,
    /// How the length is determined on the wire.
    length_type: LengthType,
    /// How the data is encoded on the wire.
    encoding: FieldEncoding,
    /// Maximum data length in bytes. Auto-set to the fixed length for
    /// fixed-length fields; from opts.max_len for variable-length fields.
    max_len: usize = 0,
    /// True if this field contains nested sub-fields (e.g., DE48, DE62).
    has_subfields: bool = false,
    /// Optional human-readable name for logs and diagnostics
    /// (e.g., "PAN", "Amount, transaction"). Null on unnamed fields;
    /// `Spec.nameOf` falls back to "DE<id>".
    name: ?[]const u8 = null,
};

/// Create a field descriptor with concise syntax.
///
/// ```zig
/// field(2, .llvar, .ascii_numeric, .{ .max_len = 19, .name = "PAN" })  // PAN
/// field(3, .fixed_6, .ascii_numeric, .{})                              // processing code
/// field(48, .lllvar, .ascii_alpha, .{ .max_len = 999, .has_subfields = true })
/// ```
///
/// For fixed-length fields, max_len is derived from the length type and
/// opts.max_len is ignored.
pub fn field(
    comptime id: comptime_int,
    comptime lt: LengthType,
    comptime enc: FieldEncoding,
    comptime opts: struct { max_len: usize = 0, has_subfields: bool = false, name: ?[]const u8 = null },
) FieldDescriptor {
    const max = if (lt.fixedLen()) |fl| fl else opts.max_len;
    return .{
        .id = @intCast(id),
        .length_type = lt,
        .encoding = enc,
        .max_len = max,
        .has_subfields = opts.has_subfields,
        .name = opts.name,
    };
}

// ─── Field View (zero-copy runtime) ────────────────────────────────────────

/// A decoded field: a typed view into the source message buffer.
/// `raw` points into the original buffer — no copy.
pub const FieldView = struct {
    /// Field ID (2–128).
    field_id: u8,
    /// Wire encoding of this field.
    enc: FieldEncoding,
    /// Byte slice into the original message buffer (zero-copy).
    raw: []const u8,
    /// For numeric fields: pre-parsed value if it fits in u64.
    int_val: ?u64 = null,
};

// ─── Field Store ───────────────────────────────────────────────────────────

/// Stores decoded field data with O(1) direct-index access.
///
/// A flat array indexed by (field_id - 2) plus a presence bitset — no hash
/// maps. Field IDs start at 2 (field 1 is the bitmap indicator).
pub const FieldStore = struct {
    /// Bitset tracking which fields (2–128) have been set.
    present: std.StaticBitSet(bitmap.MAX_FIELDS),
    /// Field views. Up to MAX_FIELDS - 1 entries (fields 2–128).
    entries: [bitmap.MAX_FIELDS - 1]FieldEntry,

    const Self = @This();

    pub const FieldEntry = struct {
        raw: []const u8 = &.{},
        int_val: ?u64 = null,
    };

    pub fn init() Self {
        return .{
            .present = std.StaticBitSet(bitmap.MAX_FIELDS).initEmpty(),
            .entries = .{FieldEntry{}} ** (bitmap.MAX_FIELDS - 1),
        };
    }

    /// Convert field ID (2–128) to internal index (0–126).
    inline fn fieldIndex(field_id: usize) usize {
        return field_id - 2;
    }

    /// Check if a field is present.
    pub fn isPresent(self: Self, field_id: usize) bool {
        if (field_id < 2 or field_id > bitmap.MAX_FIELDS) return false;
        return self.present.isSet(fieldIndex(field_id));
    }

    /// Get a field's raw data (zero-copy view).
    pub fn get(self: Self, field_id: usize) ?[]const u8 {
        if (!self.isPresent(field_id)) return null;
        const entry = self.entries[fieldIndex(field_id)];
        return entry.raw;
    }

    /// Get a field's pre-parsed integer value.
    pub fn getInt(self: Self, field_id: usize) ?u64 {
        if (!self.isPresent(field_id)) return null;
        return self.entries[fieldIndex(field_id)].int_val;
    }

    /// Set a field's data.
    pub fn set(self: *Self, field_id: usize, raw: []const u8, int_val: ?u64) void {
        if (field_id < 2 or field_id > bitmap.MAX_FIELDS) return;
        const idx = fieldIndex(field_id);
        self.present.set(idx);
        self.entries[idx] = .{ .raw = raw, .int_val = int_val };
    }

    /// Clear a field.
    pub fn unset(self: *Self, field_id: usize) void {
        if (field_id < 2 or field_id > bitmap.MAX_FIELDS) return;
        const idx = fieldIndex(field_id);
        self.present.unset(idx);
        self.entries[idx] = FieldEntry{};
    }

    /// Count present fields.
    pub fn count(self: Self) usize {
        return self.present.count();
    }

    /// Iterator over present field IDs.
    pub const Iterator = struct {
        store: *const FieldStore,
        next_field: usize,

        pub fn next(self: *Iterator) ?usize {
            while (self.next_field <= bitmap.MAX_FIELDS) {
                const fid = self.next_field;
                self.next_field += 1;
                if (self.store.isPresent(fid)) return fid;
            }
            return null;
        }
    };

    pub fn iterator(self: *const FieldStore) Iterator {
        return .{ .store = self, .next_field = 2 };
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

test "field descriptor" {
    const desc = field(2, .llvar, .ascii_numeric, .{ .max_len = 19 });
    try std.testing.expectEqual(@as(comptime_int, 2), desc.id);
    try std.testing.expectEqual(LengthType.llvar, desc.length_type);
    try std.testing.expectEqual(FieldEncoding.ascii_numeric, desc.encoding);
    try std.testing.expectEqual(@as(usize, 19), desc.max_len);
}

test "field descriptor fixed" {
    const desc = field(4, .fixed_12, .ascii_numeric, .{});
    try std.testing.expectEqual(@as(usize, 12), desc.max_len);
}

test "FieldStore set/get" {
    var store = FieldStore.init();
    try std.testing.expectEqual(@as(?[]const u8, null), store.get(2));

    store.set(2, "4111111111111111", 4111111111111111);
    try std.testing.expect(store.isPresent(2));
    try std.testing.expectEqualSlices(u8, "4111111111111111", store.get(2).?);
    try std.testing.expectEqual(@as(?u64, 4111111111111111), store.getInt(2));
}

test "FieldStore unset" {
    var store = FieldStore.init();
    store.set(2, "test", null);
    store.unset(2);
    try std.testing.expect(!store.isPresent(2));
    try std.testing.expectEqual(@as(?[]const u8, null), store.get(2));
}

test "FieldStore iterator" {
    var store = FieldStore.init();
    store.set(2, "A", null);
    store.set(4, "B", null);
    store.set(7, "C", null);

    var iter = store.iterator();
    try std.testing.expectEqual(@as(?usize, 2), iter.next());
    try std.testing.expectEqual(@as(?usize, 4), iter.next());
    try std.testing.expectEqual(@as(?usize, 7), iter.next());
    try std.testing.expectEqual(@as(?usize, null), iter.next());
}

test "FieldStore out of range" {
    var store = FieldStore.init();
    store.set(1, "X", null); // field 1 doesn't exist (bitmap indicator)
    try std.testing.expect(!store.isPresent(1));
    store.set(200, "X", null); // out of range
    try std.testing.expect(!store.isPresent(200));
}
