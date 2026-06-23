//! Comptime helpers for kv-field handling: merging prefix structs and
//! distinguishing format-args tuples from named-field structs.

const std = @import("std");

/// Build a struct type whose fields are the union of `A`'s and `B`'s fields.
/// Used by `WithLogger.with` to chain prefix calls: `log.with(...).with(...)`.
pub fn MergedPrefix(comptime A: type, comptime B: type) type {
    const a_info = @typeInfo(A).@"struct";
    const b_info = @typeInfo(B).@"struct";
    const total = a_info.fields.len + b_info.fields.len;
    var names: [total][:0]const u8 = undefined;
    var types: [total]type = undefined;
    var attrs: [total]std.builtin.Type.StructField.Attributes = undefined;
    inline for (a_info.fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{};
    }
    inline for (b_info.fields, 0..) |field, i| {
        names[a_info.fields.len + i] = field.name;
        types[a_info.fields.len + i] = field.type;
        attrs[a_info.fields.len + i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn mergePrefix(a: anytype, b: anytype) MergedPrefix(@TypeOf(a), @TypeOf(b)) {
    var out: MergedPrefix(@TypeOf(a), @TypeOf(b)) = undefined;
    inline for (@typeInfo(@TypeOf(a)).@"struct".fields) |field| {
        @field(out, field.name) = @field(a, field.name);
    }
    inline for (@typeInfo(@TypeOf(b)).@"struct".fields) |field| {
        @field(out, field.name) = @field(b, field.name);
    }
    return out;
}

/// Distinguishes a `.{ "x", 42 }` format-args tuple from a
/// `.{ .key = value }` kv-fields struct. A positional tuple (including the
/// empty `.{}`) is treated as format args; a struct with named fields is
/// treated as structured kv fields.
pub fn isFmtArgs(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and info.@"struct".is_tuple;
}
