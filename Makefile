# =============================================================================
# USEZOMBIE MAKEFILE - MODULAR STRUCTURE
# =============================================================================

include make/dev.mk
include make/quality.mk
include make/test.mk
include make/build.mk
.DEFAULT_GOAL := help

help:  ## Show all available Makefile targets
	@echo "UseZombie"
	@echo ""
	@echo "Development:"
	@echo "  up                 Start all services and tail app logs"
	@echo "  down               Stop all services, remove volumes, and cleanup"
	@echo "  dev                Alias for 'make up'"
	@echo ""
	@echo "Quality & Testing:"
	@echo "  lint               Run formatter and linter"
	@echo "  test               Run all tests (unit + e2e)"
	@echo "  doctor             Run zombied doctor (connectivity + config check)"
	@echo ""
	@echo "Build & Deploy:"
	@echo "  build              Build production container"
	@echo "  build-dev          Build development container"
	@echo "  push-dev           Push development image to registry"
	@echo "  push               Push production image (retag from dev-latest)"

