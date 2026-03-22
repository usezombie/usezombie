# Observability Strategy

**Date:** Mar 22, 2026
**Status:** Active

## Two Layers

| Layer | Tool | Purpose |
|---|---|---|
| Infra / ops | Grafana stack | service health, executor health, sandbox signals, traces |
| Product | PostHog | user-facing behavior, funnels, adoption, conversion |

Sandbox and executor telemetry is infra-first. It must not be hidden inside product analytics.

## Canonical Correlation Fields

- `trace_id`
- `run_id`
- `workspace_id`
- `stage_id`
- `role_id`
- `skill_id`
- `executor_id` when available

## Execution Telemetry Model

```text
worker
  -> executor.session_created
  -> executor.stage_started
  -> executor.stage_finished | executor.stage_failed
  -> executor.session_destroyed

sandbox-executor
  -> sandbox.preflight
  -> sandbox.policy_denied
  -> sandbox.timeout_kill
  -> sandbox.oom_kill
  -> sandbox.resource_usage
```

## Required Infra Signals

### Structured logs

- `executor.session_created`
- `executor.session_lost`
- `executor.stage_started`
- `executor.stage_finished`
- `executor.stage_failed`
- `sandbox.preflight`
- `sandbox.policy_denied`
- `sandbox.timeout_kill`
- `sandbox.oom_kill`

### Metrics

- `zombie_executor_sessions_total`
- `zombie_executor_session_failures_total`
- `zombie_sandbox_shell_runs_total`
- `zombie_sandbox_kill_switch_total`
- `zombie_sandbox_preflight_failures_total`
- `zombie_sandbox_oom_kills_total`
- `zombie_sandbox_memory_mb_allocated`
- `zombie_sandbox_cpu_throttled_seconds_total`

### Error codes

- `UZ-SANDBOX-001`
- `UZ-SANDBOX-002`
- `UZ-SANDBOX-003`

## Operational Interpretation

1. If worker is healthy but executor health degrades, treat that as execution-substrate failure, not application success.
2. If executor dies mid-stage, the run should show a clear infrastructure-classified failure.
3. Worker and executor upgrades should be visible as interrupted or drained runs, never silent disappearance.

## Product Analytics Boundary

PostHog should continue to track:
- run started/completed/failed
- agent completed
- workspace and CLI product usage

PostHog should not be the primary source of truth for sandbox enforcement or executor health.

