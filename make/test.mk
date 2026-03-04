# =============================================================================
# TEST — unit + integration tests
# =============================================================================

.PHONY: test test-unit test-e2e

test: test-unit ## Run all tests

test-unit: ## Run Zig unit tests
	@zig build test

test-e2e: ## Run end-to-end acceptance test (requires running server + test repo)
	@echo "E2E: POST /v1/runs"
	@curl -sf -X POST http://localhost:3000/v1/runs \
		-H "Authorization: Bearer $$API_KEY" \
		-H "Content-Type: application/json" \
		-d '{"workspace_id":"$$ACCEPTANCE_WORKSPACE_ID","spec_id":"$$ACCEPTANCE_SPEC_ID","mode":"api","requested_by":"ci","idempotency_key":"e2e-001"}' \
		| jq .
