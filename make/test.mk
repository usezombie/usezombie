# =============================================================================
# TEST — unit + integration + e2e
# =============================================================================

.PHONY: test test-unit test-integration test-e2e

ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.tmp/zig-global-cache
ZIG_LOCAL_CACHE_DIR ?= $(CURDIR)/.tmp/zig-local-cache

test-unit:  ## Run unit tests
	@echo "→ Running unit tests..."
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test

test-integration:  ## Run integration checks against a running local service
	@echo "→ Running integration checks..."
	@curl -sf http://localhost:3000/healthz | jq .
	@curl -sf http://localhost:3000/readyz | jq .

test-e2e:  ## Run e2e API flow against a running local service
	@echo "→ Running e2e tests..."
	@echo "E2E: POST /v1/runs"
	@curl -sf -X POST http://localhost:3000/v1/runs \
		-H "Authorization: Bearer $$API_KEY" \
		-H "Content-Type: application/json" \
		-d '{"workspace_id":"$$ACCEPTANCE_WORKSPACE_ID","spec_id":"$$ACCEPTANCE_SPEC_ID","mode":"api","requested_by":"ci","idempotency_key":"e2e-001"}' \
		| jq .

test: test-unit test-integration test-e2e  ## Run all tests (unit + integration + e2e)
	@echo "✓ All tests passed"
