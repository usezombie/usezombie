# UseZombie — Agent Delivery Control Plane

Date: Mar 28, 2026
Status: Active positioning baseline (replaces GTM.md)

---

## Category and Positioning

**Category:** Agent Delivery Control Plane

**Entry message:** Submit a spec. Get a validated PR. No babysitting.

**Promise:** Spec-driven pipelines with self-repairing agents, scored output, and evidence-backed PRs.

---

## What Makes UseZombie Different

1. **Spec-driven, not chat-thread driven.** Work starts from versioned specs and deterministic run state. No prompt archaeology.

2. **Self-repair gate loop.** Agents run `make lint`, `make test`, and `make build` and fix their own errors before the PR lands. You review a passing build, not a broken draft.

3. **Scored agents.** Every run produces a quality scorecard: wall time, repair loop count, token consumption, test delta. You can see whether the agent struggled or sailed through.

4. **GitHub as output.** Runs produce a PR with branch push, scorecard comment, and an agent-generated explanation. Your review queue, not a chat thread, is the delivery surface.

5. **Auto-merge on trust (Phase 2).** When a run's score exceeds a configured threshold, the PR merges autonomously. Ship when the evidence is good enough.

6. **Honest restart semantics.** Runs recover from persisted stage state. No hidden in-memory chat state, no silent retries from scratch.

---

## Current Product Story

### v1 (shipping)

- TypeScript CLI (`zombiectl`) — spec submission and run management
- Zig control plane (`zombied` API + worker + executor sidecar)
- Fly.io API, bare-metal workers connected via Tailscale
- Host-level Linux sandboxing (Landlock, cgroups, network deny)
- GitHub App automation (PR creation, branch push, scorecard comment)
- Self-repair gate loop (`make lint` / `make test` / `make build` with agent self-fix)
- Spec validation and run deduplication
- Cost control (token budgets, wall time limits, cancellation)

### v2 (next)

- Multi-agent competition with scored selection
- Score-gated auto-merge
- Progress streaming (SSE)
- Failure replay narratives
- Firecracker sandbox backend

---

## Target Users

**Solo builder.** Submit a spec, get a PR, review instead of babysit. Agent handles the implementation loop and lint/test/build gates.

**Small engineering team (2–5).** Convert spec backlog into a PR pipeline. Scorecards make agent quality visible and comparable across runs.

**Agent-to-agent.** An upstream planner agent triggers runs via API. UseZombie is the execution layer — receives the spec, delivers the PR.

---

## Messaging Guardrails

**Do say:**
- deterministic
- scored
- self-repairing
- spec-driven
- evidence-backed
- autonomous

**Do not say:**
- "AI writes your code" — UseZombie delivers validated PRs, not raw code
- "fully autonomous" — until auto-merge ships in v2, a human reviews before merge
- "agents keep running through upgrades"
- "single binary"
