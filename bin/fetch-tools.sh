#!/usr/bin/env bash
set -euo pipefail

# Fetches every pinned dev/CI tool declared in tools.env, verifying each SHA-256
# before install. Binaries go through bin/fetch-tool.sh (single source of the
# verify+install idiom); tarball tools are fetched and extracted here with the
# same `sha256sum -c` check. Idempotent: an already-present, correct tool is
# skipped.
#
#   bin/fetch-tools.sh              # all tools -> .cache/tools/bin
#   bin/fetch-tools.sh shfmt yq     # a subset (lowercase names)
#   bin/fetch-tools.sh --list       # print pinned versions, fetch nothing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tools.env"

BIN_DIR="${LARAOCI_TOOLS_DIR:-$REPO_ROOT/.cache/tools/bin}"
CACHE="${LARAOCI_TOOLS_DIR:-$REPO_ROOT/.cache/tools}/src"

list_only=0
selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_only=1; shift ;;
    -h | --help)
      echo "usage: fetch-tools.sh [--list] [tool ...]" >&2
      exit 0
      ;;
    -*) echo "error: unknown flag '$1'" >&2; exit 2 ;;
    *) selected+=("$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"); shift ;;
  esac
done

tools_to_do=()
if [[ ${#selected[@]} -gt 0 ]]; then
  tools_to_do=("${selected[@]}")
else
  # shellcheck disable=SC2206  # word-splitting the space list is intended
  tools_to_do=($LARAOCI_TOOLS)
fi

if [[ "$list_only" == 1 ]]; then
  for t in "${tools_to_do[@]}"; do
    v="${t}_VERSION"; k="${t}_KIND"
    printf '%-11s %s  (%s)\n' "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" "${!v}" "${!k}"
  done
  exit 0
fi

mkdir -p "$BIN_DIR" "$CACHE"

verify() {
  # $1 file, $2 expected sha
  if ! echo "$2  $1" | sha256sum -c - >/dev/null 2>&1; then
    echo "error: checksum mismatch for $1" >&2
    echo "       expected: $2" >&2
    echo "       actual:   $(sha256sum "$1" | cut -d' ' -f1)" >&2
    exit 1
  fi
}

for t in "${tools_to_do[@]}"; do
  url_v="${t}_URL"; sha_v="${t}_SHA256"; kind_v="${t}_KIND"; ver_v="${t}_VERSION"
  url="${!url_v:-}"; sha="${!sha_v:-}"; kind="${!kind_v:-}"; ver="${!ver_v:-}"
  lc="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$url" || -z "$sha" || -z "$kind" ]]; then
    echo "error: $t is not fully declared in tools.env" >&2
    exit 2
  fi

  case "$kind" in
    binary)
      dest="$BIN_DIR/$lc"
      if [[ -x "$dest" ]]; then
        echo "fetch-tools: $lc present, skipping" >&2
        continue
      fi
      # Reuse the single verify+install implementation.
      "$SCRIPT_DIR/fetch-tool.sh" --url "$url" --sha256 "$sha" --dest "$dest"
      ;;
    tar:*)
      inner="${kind#tar:}"
      # The runner path depends on the tool: a bare name lands in BIN_DIR, a
      # nested path (bats) is executed from its extracted tree.
      if [[ "$inner" == */* ]]; then
        marker="$CACHE/${lc}-${ver}/.done"
        runner="$CACHE/$inner"
      else
        marker="$BIN_DIR/$inner"
        runner="$BIN_DIR/$inner"
      fi
      if [[ -e "$marker" && -x "$runner" ]]; then
        echo "fetch-tools: $lc present, skipping" >&2
        continue
      fi
      tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
      curl -fsSL "$url" -o "$tmp"
      verify "$tmp" "$sha"
      if [[ "$inner" == */* ]]; then
        tar xzf "$tmp" -C "$CACHE"
        mkdir -p "$(dirname "$marker")"; : > "$marker"
      else
        # Extract just the named executable into BIN_DIR.
        tar xzf "$tmp" -C "$BIN_DIR" "$inner"
        chmod +x "$BIN_DIR/$inner"
      fi
      rm -f "$tmp"; trap - EXIT
      echo "fetch-tools: $lc ${ver} ready (sha256 verified)" >&2
      ;;
    *)
      echo "error: $t has unknown KIND '$kind'" >&2
      exit 2
      ;;
  esac
done

echo "fetch-tools: done -> $BIN_DIR" >&2
