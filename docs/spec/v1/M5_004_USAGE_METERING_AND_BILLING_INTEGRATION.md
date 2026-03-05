# M5_004: Usage Metering And Billing Integration

**Prototype:** v1.0.0
**Milestone:** M5
**Workstream:** 004
**Date:** Mar 06, 2026
**Status:** PENDING
**Priority:** P1 — required for automated subscription enforcement and billing automation
**Depends on:** M5_003 Workspace Entitlements And Plan Limits

---

## 1.0 Objective

**Status:** PENDING

Introduce deterministic workspace usage metering and billing integration contracts so plan enforcement can evolve from static policy to subscription-backed controls.

**Dimensions:**
- 1.1 PENDING Define billable usage units (`compute_seconds`, `run_count`, optional `token_units`)
- 1.2 PENDING Define metering events emitted by compile/run lifecycle
- 1.3 PENDING Define immutable usage ledger contract per workspace and billing period

---

## 2.0 Metering Pipeline

**Status:** PENDING

Capture and aggregate usage without relying on external providers at runtime.

**Dimensions:**
- 2.1 PENDING Emit usage events for run start/stop/fail with deterministic timestamps
- 2.2 PENDING Aggregate per-workspace period totals with idempotent replay handling
- 2.3 PENDING Define late event handling and backfill semantics
- 2.4 PENDING Define reconciliation process from raw events to invoice-ready summaries

---

## 3.0 Billing Adapter Contract

**Status:** PENDING

Support provider integration later without coupling core runtime to one vendor.

**Dimensions:**
- 3.1 PENDING Define billing adapter interface (`Noop`, `Manual`, provider-specific)
- 3.2 PENDING Define failure behavior when provider API is unavailable (fail closed for upgrades, no data loss)
- 3.3 PENDING Define retry/idempotency keys for charge/report operations
- 3.4 PENDING Define secure credential handling and audit trail for billing sync

---

## 4.0 Entitlement Sync And Enforcement

**Status:** PENDING

Connect billing state to plan entitlements safely.

**Dimensions:**
- 4.1 PENDING Define subscription state machine -> entitlement mapping
- 4.2 PENDING Define grace period and downgrade behavior after failed payments
- 4.3 PENDING Define deterministic enforcement timing (`next cycle` vs `immediate`)
- 4.4 PENDING Define operator-safe override path for support interventions

---

## 5.0 Acceptance Criteria

**Status:** PENDING

- [ ] 5.1 Usage ledger is reproducible from raw events and replay-safe
- [ ] 5.2 Adapter outage does not corrupt usage accounting
- [ ] 5.3 Entitlements can be derived from subscription state without manual edits
- [ ] 5.4 Default deployment can run with `Noop`/`Manual` adapter until provider API is integrated
- [ ] 5.5 Upgrade path from static plan policy (M5_003) to subscription-backed policy is documented and testable

---

## 6.0 Out of Scope

- Building a customer-facing billing dashboard UI
- Implementing a specific third-party billing provider in this workstream
- Reselling LLM tokens (BYOK remains the operating model)
