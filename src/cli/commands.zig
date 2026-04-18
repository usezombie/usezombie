const std = @import("std");

pub const Subcommand = enum {
    serve,
    worker,
    doctor,
    migrate,
    reconcile,
};

pub fn parseSubcommandName(name: []const u8) Subcommand {
    return std.meta.stringToEnum(Subcommand, name) orelse .serve;
}

pub fn parseSubcommandFromProcessArgs() Subcommand {
    var args = std.process.args();
    _ = args.next();
    const cmd = args.next() orelse return .serve;
    return parseSubcommandName(cmd);
}

test "parseSubcommandName returns known subcommands" {
    try std.testing.expectEqual(Subcommand.serve, parseSubcommandName("serve"));
    try std.testing.expectEqual(Subcommand.worker, parseSubcommandName("worker"));
    try std.testing.expectEqual(Subcommand.doctor, parseSubcommandName("doctor"));
    try std.testing.expectEqual(Subcommand.migrate, parseSubcommandName("migrate"));
    try std.testing.expectEqual(Subcommand.reconcile, parseSubcommandName("reconcile"));
}

test "parseSubcommandName defaults to serve for unknown values" {
    try std.testing.expectEqual(Subcommand.serve, parseSubcommandName("unknown"));
    try std.testing.expectEqual(Subcommand.serve, parseSubcommandName("help"));
    try std.testing.expectEqual(Subcommand.serve, parseSubcommandName("run"));
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
