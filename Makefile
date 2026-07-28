# LaraOCI convenience targets.
#
# This Makefile is DEVELOPER SUGAR ONLY. Every recipe is a single delegation to
# a script under bin/ or to an already-pinned tool - it contains no logic of its
# own. That rule is not stylistic: the logic in bin/*.sh is shellcheck-clean and
# covered by tests/unit, and CI invokes those scripts directly. A recipe that
# grew real behaviour would be untested code on a second execution path, exactly
# the drift the bats migration removed. tests/unit/makefile.bats enforces the
# one-line-delegate rule so this stays true.
#
# CI does NOT use this file; it calls bin/*.sh directly. `make` is not required
# to build, test, or release LaraOCI - only to save typing locally.

# Each recipe is one shell; keep them single commands. No .ONESHELL (its failure
# semantics differ and would hide errors in a multi-line recipe).
.DEFAULT_GOAL := help

# bin/fetch-bats.sh fetches the SHA-pinned runner and prints its path. Assigned
# with = (recursive), not :=, so `make help` does not trigger a bats download.
BATS = $$(bin/fetch-bats.sh --path)

# Overridable on the command line: `make affected BASE=origin/main`
BASE ?= origin/main
IMAGE ?=

.PHONY: help test lint fmt fmt-fix matrix affected sizes structure hooks

help: ## List available targets
	@grep -hE '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) \
	| sort | awk -F':.*## ' '{ printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2 }'

test: ## Run the unit test suite under the pinned bats
	$(BATS) tests/unit

lint: ## shellcheck every tracked shell script
	shellcheck -S warning $$(git ls-files '*.sh')

fmt: ## Check shell formatting (no changes)
	shfmt -d -i 2 -ci $$(git ls-files '*.sh')

fmt-fix: ## Apply shell formatting in place
	shfmt -w -i 2 -ci $$(git ls-files '*.sh')

matrix: ## Print the full CI build matrix as JSON
	bin/matrix.sh

affected: ## Images affected since BASE (default origin/main)
	bin/affected.sh --base $(BASE)

sizes: ## Report image sizes against their budgets (advisory)
	bin/size-check.sh --report

structure: ## Run container-structure-test for IMAGE (e.g. make structure IMAGE=runtime REF=ghcr.io/laraoci/fpm:8.4-trixie)
	bin/structure-test.sh --image $(IMAGE) --ref $(REF)

hooks: ## Print the local pre-commit sequence to run before pushing
	@printf 'make fmt && make lint && make test\n'
