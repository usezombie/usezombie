//! Pipeline topology profile loader.
//! Converts JSON config into a validated deterministic stage list.

const std = @import("std");

pub const TopologyError = error{
    InvalidProfile,
    MissingGateStage,
    GateStageMustBeLast,
    GateRoleMustBeWarden,
    FirstStageMustBeEcho,
    UnknownRole,
    DuplicateStageId,
};

pub const StageRole = enum {
    echo,
    scout,
    warden,

    pub fn parse(raw: []const u8) ?StageRole {
        if (std.ascii.eqlIgnoreCase(raw, "echo")) return .echo;
        if (std.ascii.eqlIgnoreCase(raw, "scout")) return .scout;
        if (std.ascii.eqlIgnoreCase(raw, "warden")) return .warden;
        return null;
    }

    pub fn label(self: StageRole) []const u8 {
        return @tagName(self);
    }
};

pub const Stage = struct {
    stage_id: []u8,
    role_id: []u8,
    role: StageRole,
    artifact_name: []u8,
    commit_message: []u8,
    is_gate: bool,
};

pub const Profile = struct {
    profile_id: []u8,
    stages: []Stage,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Profile) void {
        self.alloc.free(self.profile_id);
        for (self.stages) |stage| {
            self.alloc.free(stage.stage_id);
            self.alloc.free(stage.role_id);
            self.alloc.free(stage.artifact_name);
            self.alloc.free(stage.commit_message);
        }
        self.alloc.free(self.stages);
    }

    pub fn gateStage(self: *const Profile) Stage {
        return self.stages[self.stages.len - 1];
    }

    pub fn buildStages(self: *const Profile) []const Stage {
        return self.stages[1 .. self.stages.len - 1];
    }
};

const StageDoc = struct {
    stage_id: []const u8,
    role: []const u8,
    artifact_name: ?[]const u8 = null,
    commit_message: ?[]const u8 = null,
    gate: ?bool = null,
};

const ProfileDoc = struct {
    profile_id: []const u8,
    stages: []const StageDoc,
};

pub fn loadProfile(alloc: std.mem.Allocator, path: []const u8) !Profile {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return defaultProfile(alloc),
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(alloc, 256 * 1024);
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(ProfileDoc, alloc, raw, .{});
    defer parsed.deinit();
    return fromDoc(alloc, parsed.value);
}

pub fn defaultProfile(alloc: std.mem.Allocator) !Profile {
    return Profile{
        .profile_id = try alloc.dupe(u8, "default-v1"),
        .stages = try alloc.dupe(Stage, &[_]Stage{
            .{
                .stage_id = try alloc.dupe(u8, "plan"),
                .role_id = try alloc.dupe(u8, "echo"),
                .role = .echo,
                .artifact_name = try alloc.dupe(u8, "plan.json"),
                .commit_message = try alloc.dupe(u8, "echo: add plan.json"),
                .is_gate = false,
            },
            .{
                .stage_id = try alloc.dupe(u8, "implement"),
                .role_id = try alloc.dupe(u8, "scout"),
                .role = .scout,
                .artifact_name = try alloc.dupe(u8, "implementation.md"),
                .commit_message = try alloc.dupe(u8, "scout: add implementation.md"),
                .is_gate = false,
            },
            .{
                .stage_id = try alloc.dupe(u8, "verify"),
                .role_id = try alloc.dupe(u8, "warden"),
                .role = .warden,
                .artifact_name = try alloc.dupe(u8, "validation.md"),
                .commit_message = try alloc.dupe(u8, "warden: add validation.md"),
                .is_gate = true,
            },
        }),
        .alloc = alloc,
    };
}

fn fromDoc(alloc: std.mem.Allocator, doc: ProfileDoc) !Profile {
    if (doc.stages.len < 3) return TopologyError.InvalidProfile;

    const profile_id = try alloc.dupe(u8, doc.profile_id);
    errdefer alloc.free(profile_id);

    var stages = std.ArrayList(Stage).empty;
    errdefer {
        for (stages.items) |stage| {
            alloc.free(stage.stage_id);
            alloc.free(stage.role_id);
            alloc.free(stage.artifact_name);
            alloc.free(stage.commit_message);
        }
        stages.deinit(alloc);
    }

    var seen_ids = std.StringHashMap(void).init(alloc);
    defer seen_ids.deinit();

    for (doc.stages, 0..) |stage_doc, idx| {
        const role = StageRole.parse(stage_doc.role) orelse return TopologyError.UnknownRole;

        if (stage_doc.stage_id.len == 0) return TopologyError.InvalidProfile;
        if (seen_ids.contains(stage_doc.stage_id)) return TopologyError.DuplicateStageId;
        try seen_ids.put(stage_doc.stage_id, {});

        const artifact_default = switch (role) {
            .echo => "plan.json",
            .scout => "implementation.md",
            .warden => "validation.md",
        };
        const artifact_name = try alloc.dupe(u8, stage_doc.artifact_name orelse artifact_default);
        errdefer alloc.free(artifact_name);

        const commit_default = switch (role) {
            .echo => "echo: add plan.json",
            .scout => "scout: add implementation.md",
            .warden => "warden: add validation.md",
        };
        const commit_message = try alloc.dupe(u8, stage_doc.commit_message orelse commit_default);
        errdefer alloc.free(commit_message);

        const is_gate = stage_doc.gate orelse (idx == doc.stages.len - 1);

        try stages.append(alloc, .{
            .stage_id = try alloc.dupe(u8, stage_doc.stage_id),
            .role_id = try alloc.dupe(u8, stage_doc.role),
            .role = role,
            .artifact_name = artifact_name,
            .commit_message = commit_message,
            .is_gate = is_gate,
        });
    }

    const built = try stages.toOwnedSlice(alloc);
    errdefer alloc.free(built);

    try validateProfile(built);

    return .{
        .profile_id = profile_id,
        .stages = built,
        .alloc = alloc,
    };
}

fn validateProfile(stages: []const Stage) !void {
    if (stages.len < 3) return TopologyError.InvalidProfile;
    if (stages[0].role != .echo) return TopologyError.FirstStageMustBeEcho;

    var gate_count: usize = 0;
    var gate_index: usize = 0;
    for (stages, 0..) |stage, i| {
        if (stage.is_gate) {
            gate_count += 1;
            gate_index = i;
        }
    }

    if (gate_count != 1) return TopologyError.MissingGateStage;
    if (gate_index != stages.len - 1) return TopologyError.GateStageMustBeLast;
    if (stages[gate_index].role != .warden) return TopologyError.GateRoleMustBeWarden;
}

test "parse role supports known values" {
    try std.testing.expectEqual(@as(?StageRole, .echo), StageRole.parse("echo"));
    try std.testing.expectEqual(@as(?StageRole, .scout), StageRole.parse("SCOUT"));
    try std.testing.expectEqual(@as(?StageRole, .warden), StageRole.parse("warden"));
    try std.testing.expectEqual(@as(?StageRole, null), StageRole.parse("security"));
}

test "integration: custom profile with extra stage is accepted" {
    const alloc = std.testing.allocator;
    const doc = ProfileDoc{
        .profile_id = "custom-profile",
        .stages = &[_]StageDoc{
            .{ .stage_id = "plan", .role = "echo" },
            .{ .stage_id = "patch-a", .role = "scout", .artifact_name = "implementation-a.md" },
            .{ .stage_id = "patch-b", .role = "scout", .artifact_name = "implementation-b.md" },
            .{ .stage_id = "verify", .role = "warden", .gate = true },
        },
    };

    var profile = try fromDoc(alloc, doc);
    defer profile.deinit();

    try std.testing.expectEqualStrings("custom-profile", profile.profile_id);
    try std.testing.expectEqual(@as(usize, 4), profile.stages.len);
    try std.testing.expectEqualStrings("plan", profile.stages[0].stage_id);
    try std.testing.expectEqual(StageRole.warden, profile.gateStage().role);
    try std.testing.expectEqual(@as(usize, 2), profile.buildStages().len);
}

test "profile requires warden gate as final stage" {
    const alloc = std.testing.allocator;
    const bad = ProfileDoc{
        .profile_id = "bad",
        .stages = &[_]StageDoc{
            .{ .stage_id = "plan", .role = "echo" },
            .{ .stage_id = "verify", .role = "warden", .gate = true },
            .{ .stage_id = "patch", .role = "scout" },
        },
    };

    try std.testing.expectError(TopologyError.GateStageMustBeLast, fromDoc(alloc, bad));
}
