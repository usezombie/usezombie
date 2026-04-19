const std = @import("std");
const validate = @import("runtime_validate.zig");

test "hasUsableApiKey validates rotation list" {
    try std.testing.expect(validate.hasUsableApiKey("key1,key2"));
    try std.testing.expect(validate.hasUsableApiKey(" key1 "));
    try std.testing.expect(!validate.hasUsableApiKey(""));
    try std.testing.expect(!validate.hasUsableApiKey(" , , "));
}

test "isHexString validates encryption key format" {
    try std.testing.expect(validate.isHexString("abcdef0123"));
    try std.testing.expect(!validate.isHexString("abcxyz"));
    try std.testing.expect(validate.isHexString("")); // vacuously true; load() length-checks separately
}
