# M5_003: Workspace Entitlements And Plan Limits

**Prototype:** v1.0.0
**Milestone:** M5
**Workstream:** 003
**Date:** Mar 06, 2026
**Status:** PENDING
**Priority:** P0 — required before enforcing multi-tenant quotas in control plane
**Depends on:** M5_002 Harness Control Plane baseline

---

## 1.0 Objective

**Status:** PENDING

Define a deterministic entitlement policy model per workspace so control-plane validation can enforce plan limits without relying on external billing APIs.

**Dimensions:**
- 1.1 PENDING Define canonical plan tiers from website pricing (`Free`, `Pro`, `Team`, `Enterprise`) and workspace entitlement schema
- 1.2 PENDING Define entitlement source-of-truth (local DB policy table + explicit default policy)
- 1.3 PENDING Define fail-closed behavior when entitlement state is missing/invalid

---

## 2.0 Plan Policy Model

**Status:** PENDING

Specify what each plan allows and what hard limits are enforced.

**Dimensions:**
- 2.1 PENDING Define plan matrix from pricing page points:
  `Free` = 1 workspace, low concurrency, basic replay;
  `Pro` = 5 workspaces, priority queue, advanced replay;
  `Team` = unlimited workspaces, shared policies, audit export, RBAC;
  `Enterprise` = dedicated isolation and custom integrations
- 2.2 PENDING Define skill policy limits per tier (built-ins included by default, max custom skills per workspace)
- 2.3 PENDING Define harness/profile limits per tier (max stages, max active profiles, max compile jobs)
- 2.4 PENDING Define runtime usage limits per tier (monthly model minutes/token budget placeholders)
- 2.5 PENDING Define enforcement mode per limit (`REJECT`, `SOFT_WARN`) with default `REJECT`

---

## 3.0 Control Plane Enforcement Contract

**Status:** PENDING

Define where and how entitlement checks execute in compile/activate paths.

**Dimensions:**
- 3.1 PENDING Compile validation must reject disallowed skill refs and over-limit graphs
- 3.2 PENDING Activation must reject profile versions that violate workspace entitlements
- 3.3 PENDING Error contract must be operator-safe with explicit machine-readable reasons
- 3.4 PENDING Audit events must include entitlement snapshot and violated policy keys
- 3.5 PENDING BYOK contract must remain explicit: entitlement checks never imply token resale billing

---

## 4.0 Operations And Lifecycle

**Status:** PENDING

Define predictable entitlement lifecycle behavior for operators.

**Dimensions:**
- 4.1 PENDING Define monthly reset window semantics and timezone normalization
- 4.2 PENDING Define manual override path for support/admin operations
- 4.3 PENDING Define deterministic behavior on restart/replay with same entitlement snapshot
- 4.4 PENDING Define migration/backfill rules for pre-entitlement workspaces

---

## 5.0 Acceptance Criteria

**Status:** PENDING

- [ ] 5.1 Every workspace resolves to a deterministic entitlement set without external billing dependency
- [ ] 5.2 Disallowed skills and over-limit harnesses are fail-closed at compile/activate boundaries
- [ ] 5.3 Operators receive explicit error codes and actionable logs for entitlement rejections
- [ ] 5.4 Entitlement decisions are auditable and replay-safe
- [ ] 5.5 M5_002 dimension 6.2 can reference this policy as implementation source-of-truth

---

## 6.0 Out of Scope

- Real-time payment processing and invoice generation
- Customer-facing billing portal UX
- Provider-specific billing SDK lock-in
