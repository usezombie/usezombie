const std = @import("std");
const queue_consts = @import("constants.zig");

const log = std.log.scoped(.redis_queue);

pub const RedisRole = enum {
    default,
    api,
    worker,
};

pub const QueueMessage = struct {
    message_id: []u8,
    run_id: []u8,
    attempt: u32,
    workspace_id: ?[]u8,

    pub fn deinit(self: *QueueMessage, alloc: std.mem.Allocator) void {
        alloc.free(self.message_id);
        alloc.free(self.run_id);
        if (self.workspace_id) |v| alloc.free(v);
    }
};

const RespValue = union(enum) {
    simple: []u8,
    err: []u8,
    integer: i64,
    bulk: ?[]u8,
    array: ?[]RespValue,

    fn deinit(self: *RespValue, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .simple => |v| alloc.free(v),
            .err => |v| alloc.free(v),
            .bulk => |v| if (v) |s| alloc.free(s),
            .array => |v| {
                if (v) |arr| {
                    for (arr) |*item| item.deinit(alloc);
                    alloc.free(arr);
                }
            },
            .integer => {},
        }
    }
};

const Config = struct {
    host: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    use_tls: bool = false,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    lock: std.Thread.Mutex = .{},

    pub fn connectFromEnv(alloc: std.mem.Allocator, role: RedisRole) !Client {
        const url_owned = try resolveRedisUrl(alloc, role);
        defer alloc.free(url_owned);

        const cfg = try parseRedisUrl(alloc, url_owned);
        defer {
            alloc.free(cfg.host);
            if (cfg.username) |v| alloc.free(v);
            if (cfg.password) |v| alloc.free(v);
        }
        if (cfg.use_tls) return error.RedisTlsNotYetSupported;

        const stream = try std.net.tcpConnectToHost(alloc, cfg.host, cfg.port);
        var client = Client{
            .alloc = alloc,
            .stream = stream,
        };

        if (cfg.password) |pwd| {
            if (cfg.username) |usr| {
                var auth = try client.commandUnlocked(&.{ "AUTH", usr, pwd });
                defer auth.deinit(alloc);
                try ensureSimpleOk(auth);
            } else {
                var auth = try client.commandUnlocked(&.{ "AUTH", pwd });
                defer auth.deinit(alloc);
                try ensureSimpleOk(auth);
            }
        }

        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stream.close();
    }

    pub fn ping(self: *Client) !void {
        var resp = try self.command(&.{"PING"});
        defer resp.deinit(self.alloc);
        switch (resp) {
            .simple => |v| {
                if (!std.mem.eql(u8, v, "PONG")) return error.RedisPingFailed;
            },
            else => return error.RedisPingFailed,
        }
    }

    pub fn ensureConsumerGroup(self: *Client) !void {
        var resp = self.command(&.{
            "XGROUP",
            "CREATE",
            queue_consts.stream_name,
            queue_consts.consumer_group,
            "0",
            "MKSTREAM",
        }) catch |err| switch (err) {
            error.RedisCommandError => {
                // Handled below from response parsing in command() path.
                return err;
            },
            else => return err,
        };
        defer resp.deinit(self.alloc);

        switch (resp) {
            .simple => |v| {
                if (!std.mem.eql(u8, v, "OK")) return error.RedisGroupCreateFailed;
            },
            .err => |msg| {
                if (std.mem.indexOf(u8, msg, "BUSYGROUP") != null) return;
                return error.RedisGroupCreateFailed;
            },
            else => return error.RedisGroupCreateFailed,
        }
    }

    pub fn xaddRun(
        self: *Client,
        run_id: []const u8,
        attempt: u32,
        workspace_id: []const u8,
    ) !void {
        var attempt_buf: [16]u8 = undefined;
        const attempt_str = try std.fmt.bufPrint(&attempt_buf, "{d}", .{attempt});
        var resp = try self.command(&.{
            "XADD",
            queue_consts.stream_name,
            "*",
            queue_consts.field_run_id,
            run_id,
            queue_consts.field_attempt,
            attempt_str,
            queue_consts.field_workspace_id,
            workspace_id,
        });
        defer resp.deinit(self.alloc);

        switch (resp) {
            .bulk => |v| {
                if (v == null) return error.RedisXaddFailed;
            },
            else => return error.RedisXaddFailed,
        }
    }

    pub fn xack(self: *Client, message_id: []const u8) !void {
        var resp = try self.command(&.{
            "XACK",
            queue_consts.stream_name,
            queue_consts.consumer_group,
            message_id,
        });
        defer resp.deinit(self.alloc);

        switch (resp) {
            .integer => |v| if (v < 0) return error.RedisXackFailed,
            else => return error.RedisXackFailed,
        }
    }

    pub fn xreadgroupOne(self: *Client, consumer_id: []const u8) !?QueueMessage {
        var resp = try self.command(&.{
            "XREADGROUP",
            "GROUP",
            queue_consts.consumer_group,
            consumer_id,
            "COUNT",
            queue_consts.xread_count,
            "BLOCK",
            queue_consts.xread_block_ms,
            "STREAMS",
            queue_consts.stream_name,
            ">",
        });
        defer resp.deinit(self.alloc);
        return self.decodeSingleMessage(resp);
    }

    pub fn xautoclaimOne(self: *Client, consumer_id: []const u8) !?QueueMessage {
        var resp = try self.command(&.{
            "XAUTOCLAIM",
            queue_consts.stream_name,
            queue_consts.consumer_group,
            consumer_id,
            queue_consts.xautoclaim_min_idle_ms,
            queue_consts.xautoclaim_start,
            "COUNT",
            queue_consts.xautoclaim_count,
        });
        defer resp.deinit(self.alloc);
        return self.decodeAutoClaimMessage(resp);
    }

    pub fn command(self: *Client, argv: []const []const u8) !RespValue {
        self.lock.lock();
        defer self.lock.unlock();
        return self.commandUnlocked(argv);
    }

    fn commandUnlocked(self: *Client, argv: []const []const u8) !RespValue {
        var writer = self.stream.writer();
        try writer.print("*{d}\r\n", .{argv.len});
        for (argv) |arg| {
            try writer.print("${d}\r\n", .{arg.len});
            try writer.writeAll(arg);
            try writer.writeAll("\r\n");
        }

        var reader = self.stream.reader();
        const value = try readRespValue(self.alloc, &reader);
        if (value == .err) return error.RedisCommandError;
        return value;
    }

    fn decodeSingleMessage(self: *Client, value: RespValue) !?QueueMessage {
        if (value != .array) return null;
        const top = value.array orelse return null;
        if (top.len == 0) return null;
        if (top.len != 1) return error.RedisUnexpectedResponse;
        if (top[0] != .array) return error.RedisUnexpectedResponse;
        const stream_entry = top[0].array orelse return error.RedisUnexpectedResponse;
        if (stream_entry.len != 2) return error.RedisUnexpectedResponse;
        if (stream_entry[1] != .array) return error.RedisUnexpectedResponse;
        const messages = stream_entry[1].array orelse return null;
        if (messages.len == 0) return null;
        return self.decodeMessageTuple(messages[0]);
    }

    fn decodeAutoClaimMessage(self: *Client, value: RespValue) !?QueueMessage {
        if (value != .array) return null;
        const top = value.array orelse return null;
        if (top.len < 2) return error.RedisUnexpectedResponse;
        if (top[1] != .array) return error.RedisUnexpectedResponse;
        const messages = top[1].array orelse return null;
        if (messages.len == 0) return null;
        return self.decodeMessageTuple(messages[0]);
    }

    fn decodeMessageTuple(self: *Client, item: RespValue) !QueueMessage {
        if (item != .array) return error.RedisUnexpectedResponse;
        const tuple = item.array orelse return error.RedisUnexpectedResponse;
        if (tuple.len != 2) return error.RedisUnexpectedResponse;
        const msg_id = valueAsString(tuple[0]) orelse return error.RedisUnexpectedResponse;

        if (tuple[1] != .array) return error.RedisUnexpectedResponse;
        const fields = tuple[1].array orelse return error.RedisUnexpectedResponse;
        if (fields.len % 2 != 0) return error.RedisUnexpectedResponse;

        var run_id: ?[]u8 = null;
        var workspace_id: ?[]u8 = null;
        var attempt: u32 = 0;

        var i: usize = 0;
        while (i < fields.len) : (i += 2) {
            const key = valueAsString(fields[i]) orelse continue;
            const val = valueAsString(fields[i + 1]) orelse continue;

            if (std.mem.eql(u8, key, queue_consts.field_run_id)) {
                run_id = try self.alloc.dupe(u8, val);
            } else if (std.mem.eql(u8, key, queue_consts.field_workspace_id)) {
                workspace_id = try self.alloc.dupe(u8, val);
            } else if (std.mem.eql(u8, key, queue_consts.field_attempt)) {
                attempt = std.fmt.parseInt(u32, val, 10) catch 0;
            }
        }

        if (run_id == null) return error.RedisUnexpectedResponse;

        return .{
            .message_id = try self.alloc.dupe(u8, msg_id),
            .run_id = run_id.?,
            .attempt = attempt,
            .workspace_id = workspace_id,
        };
    }
};

fn valueAsString(v: RespValue) ?[]const u8 {
    return switch (v) {
        .simple => |s| s,
        .bulk => |s| s,
        .err, .integer, .array => null,
    };
}

fn ensureSimpleOk(v: RespValue) !void {
    switch (v) {
        .simple => |msg| if (!std.mem.eql(u8, msg, "OK")) return error.RedisAuthFailed,
        else => return error.RedisAuthFailed,
    }
}

fn resolveRedisUrl(alloc: std.mem.Allocator, role: RedisRole) ![]u8 {
    const primary = switch (role) {
        .api => "REDIS_URL_API",
        .worker => "REDIS_URL_WORKER",
        .default => "REDIS_URL",
    };

    if (std.process.getEnvVarOwned(alloc, primary)) |url| {
        return url;
    } else |_| {
        if (role == .default) return error.MissingRedisUrl;
        return std.process.getEnvVarOwned(alloc, "REDIS_URL") catch error.MissingRedisUrl;
    }
}

fn parseRedisUrl(alloc: std.mem.Allocator, url: []const u8) !Config {
    var cfg = Config{
        .host = undefined,
        .port = 6379,
    };

    const rest = if (std.mem.startsWith(u8, url, "redis://")) blk: {
        cfg.use_tls = false;
        break :blk url["redis://".len..];
    } else if (std.mem.startsWith(u8, url, "rediss://")) blk: {
        cfg.use_tls = true;
        break :blk url["rediss://".len..];
    } else return error.InvalidRedisUrl;

    const at_pos = std.mem.lastIndexOfScalar(u8, rest, '@');
    const hostpath = if (at_pos) |at| blk: {
        const userpass = rest[0..at];
        if (std.mem.indexOfScalar(u8, userpass, ':')) |colon| {
            if (colon > 0) cfg.username = try alloc.dupe(u8, userpass[0..colon]);
            cfg.password = try alloc.dupe(u8, userpass[colon + 1 ..]);
        } else {
            cfg.password = try alloc.dupe(u8, userpass);
        }
        break :blk rest[at + 1 ..];
    } else rest;

    const slash_pos = std.mem.indexOfScalar(u8, hostpath, '/') orelse hostpath.len;
    const hostport = hostpath[0..slash_pos];

    if (hostport.len == 0) return error.InvalidRedisUrl;

    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        cfg.host = try alloc.dupe(u8, hostport[0..colon]);
        cfg.port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.InvalidRedisUrl;
    } else {
        cfg.host = try alloc.dupe(u8, hostport);
    }

    return cfg;
}

fn readRespValue(alloc: std.mem.Allocator, reader: anytype) !RespValue {
    const prefix = try reader.readByte();
    return switch (prefix) {
        '+' => RespValue{ .simple = try readRespLine(alloc, reader) },
        '-' => RespValue{ .err = try readRespLine(alloc, reader) },
        ':' => blk: {
            const line = try readRespLine(alloc, reader);
            defer alloc.free(line);
            break :blk RespValue{ .integer = try std.fmt.parseInt(i64, line, 10) };
        },
        '$' => blk: {
            const line = try readRespLine(alloc, reader);
            defer alloc.free(line);
            const len = try std.fmt.parseInt(i64, line, 10);
            if (len == -1) break :blk RespValue{ .bulk = null };
            if (len < 0) return error.RedisProtocolError;

            const usize_len: usize = @intCast(len);
            const out = try alloc.alloc(u8, usize_len);
            errdefer alloc.free(out);
            try reader.readNoEof(out);
            var crlf: [2]u8 = undefined;
            try reader.readNoEof(&crlf);
            if (!std.mem.eql(u8, &crlf, "\r\n")) return error.RedisProtocolError;
            break :blk RespValue{ .bulk = out };
        },
        '*' => blk: {
            const line = try readRespLine(alloc, reader);
            defer alloc.free(line);
            const count = try std.fmt.parseInt(i64, line, 10);
            if (count == -1) break :blk RespValue{ .array = null };
            if (count < 0) return error.RedisProtocolError;
            const usize_count: usize = @intCast(count);
            const arr = try alloc.alloc(RespValue, usize_count);
            errdefer alloc.free(arr);
            for (arr, 0..) |*item, idx| {
                item.* = readRespValue(alloc, reader) catch |err| {
                    var j: usize = 0;
                    while (j < idx) : (j += 1) arr[j].deinit(alloc);
                    return err;
                };
            }
            break :blk RespValue{ .array = arr };
        },
        else => error.RedisProtocolError,
    };
}

fn readRespLine(alloc: std.mem.Allocator, reader: anytype) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    while (true) {
        const b = try reader.readByte();
        if (b == '\r') {
            const next = try reader.readByte();
            if (next != '\n') return error.RedisProtocolError;
            break;
        }
        try buf.append(alloc, b);
    }

    return buf.toOwnedSlice(alloc);
}

pub fn makeConsumerId(alloc: std.mem.Allocator) ![]u8 {
    var host_buf: [64]u8 = undefined;
    const host = std.posix.gethostname(&host_buf) catch "localhost";
    const now = std.time.nanoTimestamp();
    return std.fmt.allocPrint(alloc, "{s}-{s}-{d}", .{
        queue_consts.consumer_prefix,
        host,
        now,
    });
}

test "parseRedisUrl handles redis URL variants" {
    const alloc = std.testing.allocator;

    const local = try parseRedisUrl(alloc, "redis://localhost:6379");
    defer alloc.free(local.host);
    try std.testing.expectEqualStrings("localhost", local.host);
    try std.testing.expectEqual(@as(u16, 6379), local.port);
    try std.testing.expect(!local.use_tls);

    const auth = try parseRedisUrl(alloc, "redis://user:pass@cache.local:6380");
    defer {
        alloc.free(auth.host);
        if (auth.username) |v| alloc.free(v);
        if (auth.password) |v| alloc.free(v);
    }
    try std.testing.expectEqualStrings("cache.local", auth.host);
    try std.testing.expectEqualStrings("user", auth.username.?);
    try std.testing.expectEqualStrings("pass", auth.password.?);
    try std.testing.expectEqual(@as(u16, 6380), auth.port);

    const tls = try parseRedisUrl(alloc, "rediss://default:secret@upstash.local:6379");
    defer {
        alloc.free(tls.host);
        if (tls.username) |v| alloc.free(v);
        if (tls.password) |v| alloc.free(v);
    }
    try std.testing.expect(tls.use_tls);
}
