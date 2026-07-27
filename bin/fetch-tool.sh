#!/usr/bin/env bash
set -euo pipefail

# Downloads a pinned CI tool and verifies its SHA-256 before installing it.
#
# Every `uses:` in this repository is pinned to a commit SHA and the PHP
# extension installer is pinned by digest. The curl-installed CI binaries were
# the one unpinned link in that chain: a version in a URL prevents drift but not
# substitution, because a release asset can be replaced in place (L5).
#
# Installs to a path the runner already owns, so no step needs sudo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

url=""
sha256=""
dest=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      require_arg "$1" "${2:-}"
      url="$2"
      shift 2
      ;;
    --sha256)
      require_arg "$1" "${2:-}"
      sha256="$2"
      shift 2
      ;;
    --dest)
      require_arg "$1" "${2:-}"
      dest="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: fetch-tool.sh --url URL --sha256 HEX --dest PATH" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

for required in url sha256 dest; do
  if [[ -z "${!required}" ]]; then
    echo "error: --$required is required" >&2
    exit 2
  fi
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL "$url" -o "$tmp"

# `sha256sum -c` reads "<hex>  <path>" and exits non-zero on a mismatch. The
# check is what makes this script worth having, so its failure must be loud.
if ! echo "$sha256  $tmp" | sha256sum -c - >/dev/null 2>&1; then
  echo "error: checksum mismatch for $url" >&2
  echo "       expected: $sha256" >&2
  echo "       actual:   $(sha256sum "$tmp" | cut -d' ' -f1)" >&2
  exit 1
fi

install -m 0755 "$tmp" "$dest"
echo "fetch-tool: installed $(basename "$dest") from $url (sha256 verified)"
