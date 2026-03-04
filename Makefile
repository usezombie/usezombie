# UseZombie Makefile (modular)

include make/dev.mk
include make/quality.mk
include make/test.mk
include make/build.mk

.DEFAULT_GOAL := help

help: ## Show available make targets
	@grep -h -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'
