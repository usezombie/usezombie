# =============================================================================
# DEV — local development
# =============================================================================

.PHONY: dev up down logs db-shell migrate

VERSION ?= $(shell cat VERSION 2>/dev/null || echo "0.1.0")

dev: ## Start local Postgres + run zombied serve
	@docker compose up -d db
	@sleep 1
	@zig build run -- serve

up: ## Start all services via docker compose
	@docker compose up -d

down: ## Stop all services
	@docker compose down

logs: ## Tail docker compose logs
	@docker compose logs -f

db-shell: ## Open psql to local Postgres
	@psql "$$DATABASE_URL"

migrate: ## Apply schema migrations manually
	@psql "$$DATABASE_URL" < schema/001_initial.sql && echo "migrations applied"
