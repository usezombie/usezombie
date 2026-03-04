# M2_006: Website Build Prompt (Humans + Agents, Neon Direction)

Date: Mar 2, 2026 (migrated from PENDING2_006)
Status: PENDING — M2 scope, execute after M1 control plane ships first successful PR
Depends on: M1_000, M2_004

Use this prompt in a new build/design session to produce the first production-ready Clawable website.

## Prompt

You are `ORACLE-WEB-ARCHITECT` and `FRONTEND-DESIGN-ENGINEER`.

Design and implement the first shippable Clawable marketing website with **two parallel go-to-market tracks** and explicit mode switching:

1. Human buyers/operators (DevEx/platform teams, founders, engineers)
2. Agent-native consumers (machine-readable onboarding, API-first discovery)

This is not a generic landing page. Build a deliberate, high-contrast, neon visual system with operational credibility.

## Product Context

Clawable is an **Agent Delivery Control Plane**:

- It turns spec queues into governed PR delivery.
- It provides run replay, policy controls, and reliability telemetry.
- It supports human operation (web/chat/voice) and agent operation (skill/openapi endpoints).
- Revenue model: BYOK (users bring their own LLM API keys) + compute billing (per agent-second).
- Phase 1 ICP: solo builders and small teams (2-10 engineers). Phase 2: platform teams in 20-200 orgs.

Human GTM and agent GTM must coexist in one coherent site architecture.

## Inputs to honor

### Agent-facing inspiration

Use `actors.dev`/`actor.dev` patterns as inspiration for agent UX:

- clear "agent-first" messaging,
- machine-readable onboarding surface (`skill.md`, `openapi.json`, docs page),
- explicit API contract references,
- simple "start here" flow for autonomous agents.

Concrete patterns observed on actors.dev that must influence `/agents`:

1. explicit machine-first framing ("this page is for autonomous agents"),
2. one-line bootstrap command (`curl .../skill.md`),
3. `openapi.json` as canonical contract, docs as secondary,
4. JSON-LD discoverability for machine parsers,
5. capability + safety limits shown together (not hidden in footer).

### Visual direction

Use neon-focused styling inspired by `clawcontrol` / `openclaw` / `ampcode` vibe and local references, but shift to an **orangish neon primary tone**:

- `/Users/kishore/Documents/designs/neon_green.png`
- `/Users/kishore/Documents/designs/neon_green_font.png`

Observed style cues from references:

1. Deep near-black background with subtle texture/noise.
2. Neon orange/amber glows as primary, with restrained cyan accents.
3. Mono/tech typography for badges/headlines.
4. Floating wireframe/circuit motifs and luminous line-work.
5. Dark elevated cards with thin borders and soft glow.

Text/typography cues extracted from local PNGs:

1. Terminal-like mono headline treatment on critical cards.
2. Uppercase neon status badge pattern (for example: "YOU'VE BEEN INVITED AS A HACKER!").
3. Sparse, high-contrast form layouts with subtle border glow.
4. Minimal copy density and strong hierarchy between headline and supporting copy.

Do not default to generic white SaaS style.  
Do not use purple-biased palettes.

## Required information architecture

Global requirement:

1. Top navigation includes a clear mode switch: `Humans | Agents`.
2. `Humans` defaults to `/`.
3. `Agents` routes to `/agents`.
4. Persist last selected mode in local storage for return visits.

### Route 1: `/` (Human-facing)

Sections:

1. Hero: "Ship AI-generated PRs reliably, with policy and run replay"
2. Problem: current agent chaos (unreliable, no replay, no policy)
3. Solution: deterministic lifecycle (`spec -> run -> verify -> PR -> notify`)
4. Reliability proof: run timeline, retries, defect artifacts
5. Observability: dashboards (success rate, retries, cost per shipped PR)
6. Voice + chat operations: ElevenLabs/OpenClaw control layer
7. Pricing preview: Free / Pro / Team / Enterprise
8. CTA blocks: start free (individual) + book team pilot

### Route 2: `/agents` (Agent-facing)

Tone: direct, machine-first, minimal human fluff.

Sections:

1. "This page is for autonomous agents"
2. Start here command block with copy-paste bootstrap
3. Links to machine contracts:
   - `/skill.md`
   - `/openapi.json`
   - `/openapi-docs`
   - `/heartbeat`
   - `/llms.txt`
4. Canonical contract note: "Use `/openapi.json` as source of truth"
5. Minimal auth/owner verification flow
6. Safe usage limits + auditability guarantees
7. Webhook + callback examples for autonomous workflows

### Route 3: `/pricing`

Must support bottom-up and expansion:

1. Free (individual caps, 1 workspace, low concurrency)
2. Pro (higher limits + better replay + queue priority)
3. Team (shared workspaces + RBAC + policy + audit)
4. Enterprise (SSO, compliance, dedicated isolation, contractual SLA)

Pricing model notes (align with `docs/GTM.md`):
1. BYOK: users provide their own LLM API keys — Clawable never bills for tokens.
2. Compute billing: charge per agent-second (wall-clock time workers run Echo/Scout/Warden).
3. $5 one-time workspace activation fee.
4. Pricing page must explain BYOK clearly — this is a trust differentiator.

### Route 4: `/docs` (lightweight)

1. Quickstart
2. API basics
3. Voice command classes (safe/sensitive/critical)
4. Reliability model and lifecycle states

## Required machine-readable assets

Generate starter artifacts (can be static placeholders initially):

1. `public/skill.md`
2. `public/openapi.json` (minimal valid schema)
3. `public/heartbeat` (simple JSON status)
4. `public/llms.txt` (concise curated map to docs/specs/endpoints)
5. JSON-LD snippet on `/agents` describing service + API entry points
6. `public/agent-manifest.json` (machine-readable capability + endpoint summary, per PENDING_004)

## Design system requirements

Define CSS variables/tokens, at minimum:

1. `--bg-0`, `--bg-1`, `--surface-0`
2. `--text-primary`, `--text-muted`
3. `--neon-orange`, `--neon-amber`, `--neon-cyan`, `--accent-gold`
4. `--border-subtle`, `--glow-soft`, `--glow-strong`

Suggested starting palette (adjust with contrast checks):

- `--bg-0: #06090F`
- `--bg-1: #0A0F17`
- `--surface-0: #101722`
- `--text-primary: #E8F2FF`
- `--text-muted: #8B97A8`
- `--neon-orange: #FF5A2D` (primary; OpenClaw-like lobster accent family)
- `--neon-orange-bright: #FF7A3D` (hover/active/emphasis)
- `--neon-amber: #FFB020` (warning/support accent)
- `--neon-cyan: #6EE7FF` (secondary only)
- `--accent-gold: #D7B56D`
- `--border-subtle: #1A2533`

Color usage rule:

1. Orange/amber must dominate CTAs, glow edges, and key highlights.
2. Cyan is supporting accent only (max ~20% of accent usage).
3. No purple primary gradients.
4. Visual goal is "same color family, not exact clone" of clawcontrol/openclaw/amp.

Typography:

1. Humans mode: modern sans primary with clear product readability.
2. Agents mode: mono/terminal accent for command surfaces and machine docs.
3. avoid default Inter/Roboto/Arial/system-ui as the primary brand face.
4. use all-caps badge labels sparingly for status/system-callout components.

Approved modern font direction (pick one primary + one mono pair):

1. Paid option A: `Söhne` + `Söhne Mono` (neo-grotesk, strong product tone).
2. Paid option B: `Suisse Int'l` + `Suisse Int'l Mono` (clean enterprise-modern).
3. Paid option C: `Graphik` + `ABC Diatype Mono` (neutral plus technical contrast).
4. Free/pro option: `Geist Sans` + `Geist Mono`.

Font policy requirement:

1. define explicit `--font-sans` and `--font-mono` tokens.
2. include legal/licensing note for chosen commercial font.
3. include webfont loading strategy (`font-display: swap` and subset strategy).

Motion:

1. one hero reveal sequence,
2. subtle stagger for cards,
3. restrained glow transitions (no distracting over-animation).

## Accessibility and quality constraints

1. WCAG 2.2 AA contrast compliance.
2. Keyboard-navigable interactions.
3. Semantic landmarks and headings.
4. Mobile-first responsive behavior.
5. Fast-loading hero (avoid heavy unoptimized assets).

## Technical expectations

1. Use React + TypeScript.
2. Keep components modular and reviewable.
3. No placeholder lorem ipsum.
4. Include realistic copy tied to Clawable positioning.
5. Include full state handling (loading/error/empty where relevant).

## Deliverables required from implementation

1. Working multi-route website (`/`, `/agents`, `/pricing`, `/docs`).
2. Design token file with documented palette and typography choices.
3. `skill.md`, `openapi.json`, `heartbeat` starter files.
4. Dual-mode nav component (`Humans | Agents`) with persisted preference.
5. One short brand rationale explaining how neon style supports trust + performance narrative.
6. Screenshots for desktop and mobile routes.

## Acceptance criteria

1. Clear dual-GTM narrative: humans and agents both understand where to start.
2. Agent route is actually machine-usable (not just marketing text).
3. Visual style is distinct, neon-forward, and not generic SaaS.
4. Site remains accessible and readable despite dark neon aesthetic.
5. Human conversion CTAs are unambiguous: `Start free` and `Book team pilot`.
6. `Humans | Agents` switch is obvious, fast, and consistent across routes.
7. `/agents` exposes copy-ready machine bootstrap and canonical API contract links.
8. `/llms.txt` exists and points to the same canonical machine resources.

## Out of scope for this pass

1. Full billing backend integration.
2. Complete auth implementation.
3. Full docs portal with search.
4. Complex animation libraries that hurt performance.

## Implementation dependency
Website implementation starts **after** the control plane MVP ships its first successful PR. See `docs/spec/PENDING2_004_WEBSITE_EXECUTION_PLAN.md` for the same constraint.

## Notes for the next implementer

Prefer boring, deterministic structure under the visual layer:

1. strong IA,
2. clear CTA hierarchy,
3. explicit machine entry points,
4. design tokens first, components second.

Reference URLs used for this prompt:

1. https://actors.dev/
2. https://actor.dev/
3. https://clawcontrol.app/
4. local references: `/Users/kishore/Documents/designs/neon_green.png`, `/Users/kishore/Documents/designs/neon_green_font.png`
5. https://vercel.com/font
6. https://commercialtype.com/about/collections/graphik
7. https://pangrampangram.com/products/neue-montreal
8. https://www.swisstypefaces.com/
9. https://abcdinamo.com/typefaces/diatype
10. https://fontstand.com/
