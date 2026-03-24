const std = @import("std");
const zap = @import("zap");
const pg = @import("pg");
const common = @import("handlers/common.zig");
const error_codes = @import("../errors/codes.zig");
const workspace_billing = @import("../state/workspace_billing.zig");
const workspace_credit = @import("../state/workspace_credit.zig");

pub const CreditPolicy = enum {
    none,
    execution_required,
};

pub const Requirement = struct {
    minimum_role: common.AuthRole = .user,
    credit_policy: CreditPolicy = .none,
};

pub const Access = struct {
    credit: ?workspace_credit.CreditView = null,
    billing_state: ?workspace_billing.StateView = null,

    pub fn deinit(self: Access, alloc: std.mem.Allocator) void {
        if (self.credit) |value| alloc.free(value.currency);
        if (self.billing_state) |bs| {
            alloc.free(bs.plan_sku);
            if (bs.subscription_id) |v| alloc.free(v);
        }
    }
};

fn authorizeWorkspace(
    r: zap.Request,
    req_id: []const u8,
    conn: *pg.Conn,
    principal: common.AuthPrincipal,
    workspace_id: []const u8,
) bool {
    if (common.authorizeWorkspaceAndSetTenantContext(conn, principal, workspace_id)) return true;
    common.errorResponse(r, .forbidden, error_codes.ERR_FORBIDDEN, "Workspace access denied", req_id);
    return false;
}

const ExecutionResult = struct {
    credit: workspace_credit.CreditView,
    billing_state: workspace_billing.StateView,
};

fn requireExecutionAllowed(
    r: zap.Request,
    req_id: []const u8,
    conn: *pg.Conn,
    alloc: std.mem.Allocator,
    workspace_id: []const u8,
    actor: []const u8,
) ?ExecutionResult {
    const billing_state = workspace_billing.reconcileWorkspaceBilling(conn, alloc, workspace_id, std.time.milliTimestamp(), actor) catch |err| {
        if (workspace_billing.errorCode(err)) |code| {
            common.errorResponse(r, .internal_server_error, code, workspace_billing.errorMessage(err) orelse "Workspace billing failure", req_id);
            return null;
        }
        common.internalOperationError(r, "Failed to reconcile workspace billing state", req_id);
        return null;
    };

    const credit = workspace_credit.enforceExecutionAllowed(conn, alloc, workspace_id, billing_state.plan_tier) catch |err| {
        alloc.free(billing_state.plan_sku);
        if (billing_state.subscription_id) |v| alloc.free(v);
        if (workspace_credit.errorCode(err)) |code| {
            common.errorResponse(r, .forbidden, code, workspace_credit.errorMessage(err) orelse "Workspace credit failure", req_id);
            return null;
        }
        common.internalOperationError(r, "Failed to validate workspace credit balance", req_id);
        return null;
    };

    return .{ .credit = credit, .billing_state = billing_state };
}

pub fn enforce(
    r: zap.Request,
    req_id: []const u8,
    conn: *pg.Conn,
    alloc: std.mem.Allocator,
    principal: common.AuthPrincipal,
    workspace_id: []const u8,
    actor: []const u8,
    requirement: Requirement,
) ?Access {
    if (!authorizeWorkspace(r, req_id, conn, principal, workspace_id)) return null;
    if (!common.requireRole(r, req_id, principal, requirement.minimum_role)) return null;

    return switch (requirement.credit_policy) {
        .none => .{},
        .execution_required => blk: {
            const result = requireExecutionAllowed(r, req_id, conn, alloc, workspace_id, actor) orelse return null;
            break :blk .{
                .credit = result.credit,
                .billing_state = result.billing_state,
            };
        },
    };
}
