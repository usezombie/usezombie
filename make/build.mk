# =============================================================================
# BUILD — Zig binary compilation
# =============================================================================

.PHONY: build build-release build-docker clean

build: ## Build debug binary
	@zig build

build-release: ## Build release binary (ReleaseSafe)
	@zig build -Doptimize=ReleaseSafe

build-docker: ## Build Docker image
	@docker build -t zombied:$(VERSION) .

clean: ## Remove build artifacts
	@rm -rf zig-out zig-cache .zig-cache
