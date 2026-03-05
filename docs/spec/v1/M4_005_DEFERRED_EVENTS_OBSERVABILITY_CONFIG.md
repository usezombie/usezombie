# M4_005: Deferred Events, Observability, and Config Hygiene (D4/D8/D19/D20)

**Prototype:** v1.0.0
**Milestone:** M4
**Workstream:** 005
**Date:** Mar 05, 2026
**Status:** PENDING
**Priority:** P2 — Lower priority follow-on after high-leverage guardrails
**Depends on:** M4_004 (guardrail baseline)

---

## 1.0 Scope Mapping (M3_001 Deferred Dimensions)

**Status:** PENDING

This workstream carries lower-priority deferred dimensions requested for separate tracking.

**Dimensions:**
- 1.1 PENDING D4 Event bus durability and replay model
- 1.2 PENDING D8 Structured logging backend strategy (`MultiObserver`/durable sink)
- 1.3 PENDING D19 Telemetry/tracing normalization (collector-friendly context model)
- 1.4 PENDING D20 Configuration and secret hygiene evolution (versioned envelopes + rotation model)

---

## 2.0 Implementation Areas

**Status:** PENDING

### 2.1 Eventing

**Dimensions:**
- 2.1.1 PENDING Introduce durable event persistence or outbox-backed replay boundary for bus events
- 2.1.2 PENDING Define versioned event schema for state/policy/agent telemetry payloads

### 2.2 Observability

**Dimensions:**
- 2.2.1 PENDING Define canonical trace context (`trace_id`/`span_id` + `request_id`) across HTTP, worker, state, and policy
- 2.2.2 PENDING Add OTEL/collector export path while keeping Prometheus metrics as first-class

### 2.3 Config and Secret Hygiene

**Dimensions:**
- 2.3.1 PENDING Introduce key-versioned encryption envelope metadata
- 2.3.2 PENDING Document and verify key rotation workflow without downtime

---

## 3.0 Acceptance Criteria

**Status:** PENDING

- [ ] 3.1 D4, D8, D19, and D20 have explicit implementation and verification evidence
- [ ] 3.2 Telemetry is collector-friendly (OTEL-ready context model) without regressing Prometheus metrics
- [ ] 3.3 Durable/event replay strategy is documented with failure-mode behavior
- [ ] 3.4 Config/secret evolution path is documented and testable

---

## 4.0 Out of Scope

- Reworking core run-state model or queue semantics
- UI/dashboard observability features
- Full distributed tracing backend operations runbook for production SRE
