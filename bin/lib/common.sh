#!/usr/bin/env bash

# Sourced by bin/matrix.sh, bin/affected.sh, bin/size-check.sh.
# Not executed directly; inherits `set -euo pipefail` from the caller.

# CONFIG can be overridden (used by tests with fixtures); defaults to the
# single source of truth.
: "${CONFIG:=config/images.yml}"

# Fail loudly if the wrong `yq` is on PATH. GitHub-hosted runners ship
# mikefarah/yq (Go); kislyuk/yq is a Python wrapper around jq with an
# incompatible syntax. Assert the flavour rather than producing confusing
# downstream failures.
require_mikefarah_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "error: 'yq' not found. Install mikefarah/yq v4: https://github.com/mikefarah/yq" >&2
    exit 1
  fi

  if ! yq --version 2>&1 | grep -qi mikefarah; then
    echo "error: wrong 'yq' on PATH. This project requires mikefarah/yq v4 (Go)," >&2
    echo "       not kislyuk/yq (the Python jq wrapper); their syntaxes differ." >&2
    echo "       found: $(yq --version 2>&1)" >&2
    exit 1
  fi
}
