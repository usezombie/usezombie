const std = @import("std");

pub const Subcommand = enum {
    serve,
    worker,
    doctor,
    migrate,
    reconcile,
};

/// Returns null for unknown tokens so the caller can fail loudly.
/// Silent fallback to `.serve` would let a stale `zombied run` invocation
/// start the HTTP server instead of erroring out.
pub fn parseSubcommandName(name: []const u8) ?Subcommand {
    return std.meta.stringToEnum(Subcommand, name);
}

/// Parse argv[1] into a Subcommand. Returns `.serve` when argv has no
/// subcommand (the historical default), or an error when the given token
/// is not a known subcommand.
pub fn parseSubcommandFromProcessArgs() !Subcommand {
    var args = std.process.args();
    _ = args.next();
    const cmd = args.next() orelse return .serve;
    return parseSubcommandName(cmd) orelse error.UnknownSubcommand;
}

test "parseSubcommandName returns known subcommands" {
    try std.testing.expectEqual(@as(?Subcommand, .serve), parseSubcommandName("serve"));
    try std.testing.expectEqual(@as(?Subcommand, .worker), parseSubcommandName("worker"));
    try std.testing.expectEqual(@as(?Subcommand, .doctor), parseSubcommandName("doctor"));
    try std.testing.expectEqual(@as(?Subcommand, .migrate), parseSubcommandName("migrate"));
    try std.testing.expectEqual(@as(?Subcommand, .reconcile), parseSubcommandName("reconcile"));
}

test "parseSubcommandName returns null for unknown values" {
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommandName("unknown"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommandName("help"));
    // `run` must not silently map to any real subcommand.
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommandName("run"));
}

test "Subcommand enum has no run variant" {
    const fields = @typeInfo(Subcommand).@"enum".fields;
    comptime var has_run = false;
    comptime {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "run")) has_run = true;
        }
    }
    try std.testing.expect(!has_run);
    try std.testing.expectEqual(@as(usize, 5), fields.len);
}
