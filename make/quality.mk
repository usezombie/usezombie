# =============================================================================
# QUALITY — code quality, formatting, analysis
# =============================================================================

.PHONY: fmt fmt-check doctor

fmt: ## Format all Zig source files
	@find src -name '*.zig' -exec zig fmt {} \;

fmt-check: ## Check formatting without modifying files
	@find src -name '*.zig' -exec zig fmt --check {} \;

doctor: ## Run zombied doctor (connectivity + config check)
	@zig build run -- doctor
