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

# fetch-tools.sh --path ensures the pinned bats is present and prints its path.
# Assigned with = (recursive), not :=, so `make help` triggers no download.
BATS = $$(bin/fetch-tools.sh --path bats)

# All pinned linters/formatters land here via `make tools`. Recipes call the
# cached binaries so local runs use the same pinned versions as CI.
TOOLS_BIN = .cache/tools/bin

# Overridable on the command line: `make affected BASE=origin/main`
BASE ?= origin/main
IMAGE ?=

.PHONY: help tools test lint fmt fmt-fix matrix affected sizes structure actions hooks

help: ## List available targets
	@grep -hE '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) \
	| sort | awk -F':.*## ' '{ printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2 }'

tools: ## Fetch all pinned dev tools (shfmt, yq, hadolint, actionlint, bats)
	bin/fetch-tools.sh

test: ## Run the unit test suite under the pinned bats
	$(BATS) tests/unit

lint: ## shellcheck every tracked shell script
	shellcheck -S warning $$(git ls-files '*.sh')

fmt: ## Check shell formatting (no changes)
	$(TOOLS_BIN)/shfmt -d -i 2 -ci $$(git ls-files '*.sh')

fmt-fix: ## Apply shell formatting in place
	$(TOOLS_BIN)/shfmt -w -i 2 -ci $$(git ls-files '*.sh')

matrix: ## Print the full CI build matrix as JSON
	bin/matrix.sh

affected: ## Images affected since BASE (default origin/main)
	bin/affected.sh --base $(BASE)

sizes: ## Report image sizes against their budgets (advisory)
	bin/size-check.sh --report

structure: ## Run container-structure-test for IMAGE (e.g. make structure IMAGE=runtime)
	bin/structure-test.sh --image $(IMAGE)

actions: ## Lint GitHub Actions workflows with pinned actionlint
	$(TOOLS_BIN)/actionlint

hooks: ## Print the local pre-commit sequence to run before pushing
	@printf 'make tools && make fmt && make lint && make actions && make test\n'
