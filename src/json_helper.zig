const std = @import("std");
const json = std.json;

pub const Value = json.Value;
pub const ObjectMap = json.ObjectMap;
pub const Array = json.Array;

/// Create a JSON string value
pub fn string(s: []const u8) Value {
    return .{ .string = s };
}

/// Create a JSON integer value
pub fn integer(i: i64) Value {
    return .{ .integer = i };
}

/// Create a JSON bool value
pub fn boolean(b: bool) Value {
    return .{ .bool = b };
}

/// Create an empty JSON object
pub fn object(alloc: std.mem.Allocator) ObjectMap {
    return ObjectMap.init(alloc);
}

/// Create an empty JSON array
pub fn array(alloc: std.mem.Allocator) Array {
    return Array.init(alloc);
}

/// Put a key-value pair into an ObjectMap
pub fn put(map: *ObjectMap, key: []const u8, value: Value) !void {
    try map.put(key, value);
}

/// Stringify a JSON value to an allocated string
pub fn stringify(alloc: std.mem.Allocator, value: Value) ![]const u8 {
    return try json.Stringify.valueAlloc(alloc, value, .{});
}

/// Get a string field from a JSON object
pub fn getString(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Get an integer field from a JSON object
pub fn getInt(value: Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

/// Get an object field from a JSON object
pub fn getObject(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}

/// Get an array field from a JSON object
pub fn getArray(value: Value, key: []const u8) ?[]const Value {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v != .array) return null;
    return v.array.items;
}

/// Parse a JSON string into a Value
pub fn parse(alloc: std.mem.Allocator, input: []const u8) !json.Parsed(Value) {
    return try json.parseFromSlice(Value, alloc, input, .{
        .allocate = .alloc_always,
    });
}
