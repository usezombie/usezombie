# =============================================================================
# TEST — unit + integration + e2e
# =============================================================================

.PHONY: test test-unit test-unit-zombied test-unit-website test-integration test-integration-zombied test-depth test-e2e qa qa-smoke

ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.tmp/zig-global-cache
ZIG_LOCAL_CACHE_DIR  ?= $(CURDIR)/.tmp/zig-local-cache

# --- Unit tests ---

test-unit-zombied:  ## Run zombied unit tests (Zig)
	@echo "→ [zombied] Running Zig unit tests..."
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test --summary all
	@$(MAKE) test-depth

test-unit-website:  ## Run website unit tests (vitest)
	@echo "→ [website] Running Vitest unit tests..."
	@cd website && bun run test
	@echo "✓ [website] Unit tests passed"

test-unit: test-unit-zombied test-unit-website  ## Run all unit tests (zombied + website)
	@echo "✓ All unit tests passed"

# --- Integration tests ---

test-integration-zombied:  ## Run Zig integration tests (deterministic, no live service required)
	@echo "→ [zombied] Running Zig integration tests..."
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test -- --test-filter "integration:"

test-integration: test-integration-zombied  ## Run integration checks
	@echo "→ [zombied] Integration tests passed"

test-depth:  ## Enforce minimum test depth inventory
	@mkdir -p .tmp
	@unit_count=$$(rg -n '^test \"' src -g '*.zig' | wc -l | tr -d ' '); \
	 integration_count=$$(rg -n '^test \"integration:' src -g '*.zig' | wc -l | tr -d ' '); \
	 printf 'zombied_test_cases=%s\nzombied_integration_cases=%s\n' "$$unit_count" "$$integration_count" | tee .tmp/zombied-test-depth.txt >/dev/null; \
	 if [ "$$unit_count" -lt 25 ]; then echo "✗ expected at least 25 Zig tests, got $$unit_count"; exit 1; fi; \
	 if [ "$$integration_count" -lt 3 ]; then echo "✗ expected at least 3 Zig integration tests, got $$integration_count"; exit 1; fi; \
	 echo "✓ [zombied] test depth gate passed (unit=$$unit_count integration=$$integration_count)"

# --- E2E: API flow (zombied backend) ---

test-e2e:  ## Run e2e API flow against a running local service
	@echo "→ [zombied] Running e2e API tests..."
	@curl -sf -X POST http://localhost:3000/v1/runs \
		-H "Authorization: Bearer $$API_KEY" \
		-H "Content-Type: application/json" \
		-d '{"workspace_id":"$$ACCEPTANCE_WORKSPACE_ID","spec_id":"$$ACCEPTANCE_SPEC_ID","mode":"api","requested_by":"ci","idempotency_key":"e2e-001"}' \
		| jq .

# --- E2E: Website Playwright ---
# Local: Playwright config starts Vite dev server automatically.
# Post-deploy: BASE_URL=https://usezombie.com make qa-smoke

qa:  ## Run Playwright e2e tests (full suite)
	@echo "→ [website] Running Playwright e2e..."
	@cd website && bun run test:e2e
	@echo "✓ [website] E2E passed"

qa-smoke:  ## Run Playwright smoke tests only (fast CI gate)
	@echo "→ [website] Running Playwright smoke..."
	@cd website && bun run test:e2e:smoke
	@echo "✓ [website] Smoke passed"

# --- Aggregate ---

test: test-unit test-integration test-e2e  ## Run all backend tests (zombied unit + integration + e2e)
	@echo "✓ All backend tests passed"
