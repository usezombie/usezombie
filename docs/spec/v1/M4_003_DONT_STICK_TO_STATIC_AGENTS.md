# M4_003: Dynamic Agent Topology (Don’t Stick To Static Agents)

Date: Mar 5, 2026
Status: PENDING
Priority: P0 — must start before Redis/CLI to avoid control-flow rework
Depends on: M3_001 reliability hardening baseline

---

## Execution Position Recommendation

- Start this before M3_004 implementation hardens queue semantics so worker control flow is not reworked twice.
- Keep default profile behavior stable (`echo -> scout -> warden`) while introducing config-driven topology.
- Require completion before M4_001 CLI behavior is frozen.

---

## Goal

Remove the hard-coded assumption that the pipeline is always exactly:

`Echo -> Scout -> Warden`

and replace it with a config-driven, registry-based stage system so new agents/stages can be added without rewriting worker control flow.

---

## Why This Is Needed Now

If we postpone this until after CLI and publish milestones, we lock internal run semantics to fixed roles and create migration risk for run-state, metrics, and retries.

This milestone should start during Part 1 so all subsequent work (CLI, observability, policy) targets a flexible stage topology.

---

## Current Constraint

Hard-coded role execution currently lives in:

- `src/pipeline/worker.zig`
- `src/pipeline/agents.zig`

This creates structural coupling to three roles and blocks extension (for example planner variants, security reviewer, compliance gate, post-merge verifier).

---

## Target Architecture

### 1. Agent registry

Introduce a registry of agent roles and runner bindings:

- role id
- prompt source
- tool profile
- retry policy
- timeout policy
- run function binding

### 2. Stage pipeline config

Define a pipeline config model where each stage declares:

- `stage_id`
- `role`
- `input_sources`
- `artifacts_written`
- `on_pass` transition target
- `on_fail` transition target
- `max_retries`

### 3. Deterministic execution engine

Worker executes stage graph deterministically (no dynamic branching ambiguity in v1).

### 4. Backward compatibility

When no custom pipeline config exists, default to:

`echo -> scout -> warden`

with current semantics preserved.

---

## File-Level Implementation Guidance

### `src/pipeline/agents.zig`

- Extract current role-specific runners into reusable role adapters.
- Add registry lookup APIs so worker can invoke by role id.
- Preserve existing role behavior as default entries.

### `src/pipeline/worker.zig`

- Replace static echo/scout/warden sequence with stage iterator driven by config.
- Keep existing transition and artifact behavior for default profile.
- Ensure retry/backoff/metrics apply per stage.

### `config/` (new config files)

- Add pipeline profile definition(s) for default v1 flow.
- Keep profile schema human-editable and deterministic.

### `src/types.zig` and/or state handling

- Ensure transition reason codes remain valid when roles expand.
- Avoid role-enum lock-in for future custom stages.

---

## Acceptance Criteria

1. Pipeline definition is config-driven, not hard-coded to 3 roles.
2. Default profile reproduces current behavior exactly.
3. Adding a new stage in config does not require worker control-flow rewrite.
4. Metrics/logging include stage and role identity for all executions.
5. Existing tests pass and at least one test covers custom-stage profile parsing/execution.

---

## Out Of Scope (for this milestone)

1. Arbitrary DAG scheduling with parallel branch joins.
2. UI for stage designer.
3. Runtime hot-reload of stage graph.

---

## Suggested Next Follow-on

- Add a second built-in profile (for example `echo -> scout -> security -> warden`) to validate extension path end-to-end.
