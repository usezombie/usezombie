# M4_003: Dynamic Agent Topology (Don’t Stick To Static Agents)

**Prototype:** v1.0.0
**Milestone:** M4
**Workstream:** 003
**Date:** Mar 05, 2026
**Status:** IN_PROGRESS
**Priority:** P0 — start before CLI freeze
**Depends on:** M3_001 reliability hardening baseline

---

## 1.0 Topology Core

**Status:** IN_PROGRESS

Replace hard-coded role order in worker control flow with a deterministic, profile-driven stage list.

**Dimensions:**
- 1.1 DONE Role registry lookup API added in `src/pipeline/agents.zig` (`lookupRole`, `runByRole`)
- 1.2 DONE Profile loader added in `src/pipeline/topology.zig` with validation (first stage echo, final gate warden)
- 1.3 DONE Worker execution now reads pipeline profile and iterates build/gate stages from config
- 1.4 PENDING Support non-built-in role adapters beyond echo/scout/warden

---

## 2.0 Compatibility and Runtime Behavior

**Status:** IN_PROGRESS

Preserve default v1 behavior while enabling extension through config changes.

**Dimensions:**
- 2.1 DONE Default profile file added at `config/pipeline-default.json` and used by runtime (`PIPELINE_PROFILE_PATH`)
- 2.2 DONE Stage-aware run logs/events now include `stage_id` and `role_id`
- 2.3 DONE Integration coverage added for custom profile parsing and default topology role resolution
- 2.4 PENDING Stage-level transition graph (`on_pass`/`on_fail`) metadata execution

---

## 3.0 Acceptance Criteria

**Status:** IN_PROGRESS

- [x] 3.1 Pipeline definition is config-driven, not hard-coded to 3 role calls
- [x] 3.2 Default profile reproduces current Echo → Scout → Warden flow
- [x] 3.3 Adding a new middle stage in profile does not require worker loop rewrite
- [x] 3.4 Logs/events include stage and role identity for executions
- [ ] 3.5 Arbitrary role plugin model beyond built-in adapters

---

## 4.0 Out of Scope

- Arbitrary DAG scheduling with branch joins
- UI stage designer
- Runtime hot-reload of profile graph
