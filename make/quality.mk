# =============================================================================
# QUALITY — code quality, formatting, analysis
# =============================================================================

.PHONY: lint doctor _fmt _fmt_check

_fmt:
	@echo "→ Formatting code..."
	@find src -name '*.zig' -exec zig fmt {} \;

_fmt_check:
	@echo "→ Checking formatting..."
	@find src -name '*.zig' -exec zig fmt --check {} \;

lint: _fmt_check _fmt  ## Run formatter and linter
	@echo "✓ All checks passed"

doctor:  ## Run zombied doctor (connectivity + config check)
	@zig build run -- doctor
