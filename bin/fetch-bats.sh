#!/usr/bin/env bash
set -euo pipefail

# Fetches the pinned bats-core tarball, verifies its SHA-256, extracts it, and
# prints the path to `bin/bats`. Same trust model as bin/fetch-tool.sh: the
# hash is the anchor, because a tagged asset can be replaced in place.
#
#   "$(bin/fetch-bats.sh --path)" tests/unit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/bats.env"

cache="${BATS_CACHE_DIR:-$REPO_ROOT/.cache/bats}"
runner="$cache/bats-core-${BATS_VERSION}/bin/bats"

print_only=0
[[ "${1:-}" == "--path" ]] && print_only=1

if [[ ! -x "$runner" ]]; then
  mkdir -p "$cache"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL "$BATS_URL" -o "$tmp"
  if ! echo "$BATS_SHA256  $tmp" | sha256sum -c - >/dev/null 2>&1; then
    echo "error: checksum mismatch for $BATS_URL" >&2
    echo "       expected: $BATS_SHA256" >&2
    echo "       actual:   $(sha256sum "$tmp" | cut -d' ' -f1)" >&2
    exit 1
  fi
  tar xzf "$tmp" -C "$cache"
  test -x "$runner" || {
    echo "error: bats runner not found after extract" >&2
    exit 1
  }
  echo "fetch-bats: bats-core ${BATS_VERSION} ready (sha256 verified)" >&2
fi

if [[ "$print_only" == 1 ]]; then
  printf '%s\n' "$runner"
else
  printf 'export BATS_BIN=%q\n' "$runner"
fi
