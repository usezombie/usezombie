//! Shared JSON value helpers for the executor module.
//!
//! Used by handler.zig, runner.zig, and client.zig to extract typed
//! fields from std.json.Value objects. Consolidated here to avoid
//! duplication across the executor module boundary.

const std = @import("std");

pub fn getStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: std.json.Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getIntOrZero(obj: std.json.Value, key: []const u8) u64 {
    if (obj != .object) return 0;
    const val = obj.object.get(key) orelse return 0;
    return switch (val) {
        .integer => |i| @intCast(@max(0, i)),
        else => 0,
    };
}

pub fn getFloat(obj: std.json.Value, key: []const u8) ?f64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

pub fn getBool(obj: std.json.Value, key: []const u8) bool {
    if (obj != .object) return false;
    const val = obj.object.get(key) orelse return false;
    return switch (val) {
        .bool => |b| b,
        else => false,
    };
}

pub fn getBoolDefaultTrue(obj: std.json.Value, key: []const u8) bool {
    if (obj != .object) return true;
    const val = obj.object.get(key) orelse return true;
    return switch (val) {
        .bool => |b| b,
        else => true,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

test "getStr returns null for missing key" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try std.testing.expect(getStr(obj, "missing") == null);
}

test "getStr returns null for non-string value" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("key", .{ .integer = 42 });
    try std.testing.expect(getStr(obj, "key") == null);
}

test "getStr returns string value" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("key", .{ .string = "value" });
    try std.testing.expectEqualStrings("value", getStr(obj, "key").?);
}

test "getStr returns null for non-object" {
    try std.testing.expect(getStr(.{ .integer = 1 }, "k") == null);
}

test "getIntOrZero returns 0 for missing key" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try std.testing.expectEqual(@as(u64, 0), getIntOrZero(obj, "missing"));
}

test "getIntOrZero returns 0 for negative integer" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("val", .{ .integer = -5 });
    try std.testing.expectEqual(@as(u64, 0), getIntOrZero(obj, "val"));
}

test "getIntOrZero returns value for valid integer" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("count", .{ .integer = 42 });
    try std.testing.expectEqual(@as(u64, 42), getIntOrZero(obj, "count"));
}

test "getFloat returns null for missing key" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try std.testing.expect(getFloat(obj, "nope") == null);
}

test "getFloat returns float for float value" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("temp", .{ .float = 0.42 });
    try std.testing.expectEqual(@as(f64, 0.42), getFloat(obj, "temp").?);
}

test "getFloat returns float for integer value" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("temp", .{ .integer = 1 });
    try std.testing.expectEqual(@as(f64, 1.0), getFloat(obj, "temp").?);
}

test "getBool returns false for missing key" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try std.testing.expect(!getBool(obj, "missing"));
}

test "getBool returns value for bool field" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("ok", .{ .bool = true });
    try std.testing.expect(getBool(obj, "ok"));
}

test "getBoolDefaultTrue returns true for missing key" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try std.testing.expect(getBoolDefaultTrue(obj, "missing"));
}

test "getBoolDefaultTrue returns explicit false" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("enabled", .{ .bool = false });
    try std.testing.expect(!getBoolDefaultTrue(obj, "enabled"));
}

test "getBoolField returns false for non-bool value" {
    const alloc = std.testing.allocator;
    var obj = std.json.Value{ .object = std.json.ObjectMap.init(alloc) };
    defer obj.object.deinit();
    try obj.object.put("flag", .{ .string = "true" });
    try std.testing.expect(!getBool(obj, "flag"));
}

test "getStringField returns null for non-object input" {
    try std.testing.expect(getStr(.{ .integer = 42 }, "key") == null);
    try std.testing.expect(getStr(.null, "key") == null);
    try std.testing.expect(getStr(.{ .bool = true }, "key") == null);
}
