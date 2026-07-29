#!/usr/bin/env bash
set -euo pipefail

# The single fetcher for every pinned dev/CI tool. All tools are declared in
# tools.env (version + URL + SHA-256 + KIND); this script is the only thing that
# downloads them, and it verifies every SHA-256 before install. There is no
# raw-URL mode by design: a fetch that is not a named tool in tools.env would be
# an unpinned link in a supply chain that is otherwise pinned end to end.
#
#   bin/fetch-tools.sh                      # all tools -> .cache/tools/bin
#   bin/fetch-tools.sh shfmt yq             # a subset (lowercase names)
#   bin/fetch-tools.sh --list               # print pinned versions, fetch nothing
#   bin/fetch-tools.sh --path bats          # ensure one tool present, print its runner path
#   bin/fetch-tools.sh --dest DIR yq        # install one named tool into DIR (on PATH)
#
# KIND semantics (from tools.env):
#   binary        -> the asset IS the executable
#   tar:PATH      -> asset is a .tar.gz; PATH is the executable inside it
#                    (a nested PATH like a/b/bats extracts the whole tree;
#                     a bare name extracts just that file)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tools.env"

BIN_DIR="${LARAOCI_TOOLS_DIR:-$REPO_ROOT/.cache/tools/bin}"
SRC_DIR="${LARAOCI_TOOLS_DIR:-$REPO_ROOT/.cache/tools}/src"

# ONE temp file for the whole run, created here and cleaned once on EXIT. A
# per-download mktemp - which is what this was - reassigns TMP and orphans the
# previous file, so the trap only ever saw the last of them and a cold fetch of
# every tool left five binaries in TMPDIR. A per-iteration trap has the opposite
# problem: armed and cleared inside the loop, it leaves a later failure with no
# cleanup armed.
TMP="$(mktemp)"
# Must return 0: as an EXIT trap this runs last, so a falsy final command would
# become the script's exit status under set -e.
cleanup() {
  rm -f "$TMP"
  return 0
}
trap cleanup EXIT

# --- argument parsing -------------------------------------------------------

list_only=0
path_mode=0
dest_override=""
selected=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      list_only=1
      shift
      ;;
    --path)
      path_mode=1
      shift
      ;;
    --dest)
      [[ -n "${2:-}" ]] || {
        echo "error: --dest requires a directory" >&2
        exit 2
      }
      dest_override="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "error: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      # A tool is NAMED as its executable (`container-structure-test`) but its
      # pins are shell variables, which cannot contain a hyphen. Normalising
      # here means both spellings work as input; without it the hyphenated -
      # and correct - name produced `CONTAINER-STRUCTURE-TEST_URL: invalid
      # variable name` and a hard exit.
      arg="${1^^}"
      selected+=("${arg//-/_}")
      shift
      ;;
  esac
done

# --path and --dest act on exactly one tool; guard that up front so the modes
# cannot be combined into ambiguous behaviour.
if [[ "$path_mode" == 1 || -n "$dest_override" ]]; then
  if [[ ${#selected[@]} -ne 1 ]]; then
    echo "error: --path and --dest require exactly one tool name" >&2
    exit 2
  fi
fi

tools_to_do=()
if [[ ${#selected[@]} -gt 0 ]]; then
  tools_to_do=("${selected[@]}")
else
  # shellcheck disable=SC2206  # word-splitting the space list is intended
  tools_to_do=($LARAOCI_TOOLS)
fi

# --- helpers ----------------------------------------------------------------

tool_declared() {
  # $1 = UPPER tool name; succeeds if it appears in the tools.env manifest.
  case " $LARAOCI_TOOLS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

download_verified() {
  # Truncate rather than mint a new path: TMP belongs to the run, not to this
  # call. `curl -o` truncates too, but being explicit keeps the ownership rule
  # readable at the one place that could break it again.
  : >"$TMP"
  curl -fsSL "$1" -o "$TMP"
  if ! echo "$2  $TMP" | sha256sum -c - >/dev/null 2>&1; then
    echo "error: checksum mismatch for $1" >&2
    echo "       expected: $2" >&2
    echo "       actual:   $(sha256sum "$TMP" | cut -d' ' -f1)" >&2
    exit 1
  fi
}

# The executable's real name on disk. Defaults to the lowercased manifest name,
# which is right for every tool whose binary has no hyphen. A tool whose real
# name does differ declares ${NAME}_BIN in tools.env rather than having one
# derived by convention - `container_structure_test` was landing in the cache
# under a name nothing on earth would look for.
tool_bin_name() {
  # Two `local`s, not one: `local a="$1" b="${a}_BIN"` expands ${a} BEFORE the
  # first assignment takes effect, so b would be built from whatever `a` held
  # globally. It happened to work here because `t` is also a loop variable at
  # top level, which is precisely the kind of accident shellcheck's SC2318 is
  # for.
  local t="$1"
  local bin_v="${t}_BIN"
  local lc
  lc="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
  echo "${!bin_v:-$lc}"
}

# Resolve the on-disk runner path for a tool without fetching.
runner_path() {
  # $1 = UPPER name; echoes the path its executable will/does live at.
  local t="$1" kind_v inner
  kind_v="${t}_KIND"
  local kind="${!kind_v}"
  local lc
  lc="$(tool_bin_name "$t")"
  case "$kind" in
    binary) echo "$BIN_DIR/$lc" ;;
    tar:*)
      inner="${kind#tar:}"
      if [[ "$inner" == */* ]]; then echo "$SRC_DIR/$inner"; else echo "$BIN_DIR/$inner"; fi
      ;;
    *)
      echo "error: $t has unknown KIND '$kind'" >&2
      exit 2
      ;;
  esac
}

# Fetch one tool into the cache (BIN_DIR/SRC_DIR). Idempotent.
fetch_one() {
  local t="$1"
  local url_v="${t}_URL" sha_v="${t}_SHA256" kind_v="${t}_KIND" ver_v="${t}_VERSION"
  local url="${!url_v:-}" sha="${!sha_v:-}" kind="${!kind_v:-}" ver="${!ver_v:-}"
  local lc
  lc="$(tool_bin_name "$t")"

  if ! tool_declared "$t"; then
    echo "error: '$lc' is not a tool declared in tools.env" >&2
    exit 2
  fi
  if [[ -z "$url" || -z "$sha" || -z "$kind" ]]; then
    echo "error: $t is not fully declared in tools.env" >&2
    exit 2
  fi

  local runner
  runner="$(runner_path "$t")"
  if [[ -x "$runner" ]]; then
    echo "fetch-tools: $lc present, skipping" >&2
    return 0
  fi

  case "$kind" in
    binary)
      download_verified "$url" "$sha"
      install -m 0755 "$TMP" "$runner"
      ;;
    tar:*)
      local inner="${kind#tar:}"
      download_verified "$url" "$sha"
      if [[ "$inner" == */* ]]; then
        tar xzf "$TMP" -C "$SRC_DIR"
      else
        tar xzf "$TMP" -C "$BIN_DIR" "$inner"
        chmod +x "$BIN_DIR/$inner"
      fi
      if [[ ! -x "$runner" ]]; then
        echo "error: $lc extracted but '$runner' is not an executable" >&2
        echo "       check ${t}_KIND in tools.env points at the right inner path" >&2
        exit 1
      fi
      ;;
  esac
  echo "fetch-tools: $lc ${ver} ready (sha256 verified)" >&2
}

# --- modes ------------------------------------------------------------------

if [[ "$list_only" == 1 ]]; then
  for t in "${tools_to_do[@]}"; do
    # tool_declared FIRST: the indirect expansions below are unbound-variable
    # crashes under set -u for a name that is not in the manifest, where every
    # other path in this script gives a sentence and exit 2.
    if ! tool_declared "$t"; then
      echo "error: '$(tool_bin_name "$t")' is not a tool declared in tools.env" >&2
      exit 2
    fi
    v="${t}_VERSION"
    k="${t}_KIND"
    printf '%-24s %s  (%s)\n' "$(tool_bin_name "$t")" "${!v}" "${!k}"
  done
  exit 0
fi

mkdir -p "$BIN_DIR" "$SRC_DIR"

if [[ "$path_mode" == 1 ]]; then
  t="${tools_to_do[0]}"
  fetch_one "$t"
  runner_path "$t"
  exit 0
fi

if [[ -n "$dest_override" ]]; then
  # Install one named tool into an arbitrary directory (e.g. a PATH dir on a
  # CI runner). The pin still comes from tools.env - only the destination is
  # the caller's choice.
  t="${tools_to_do[0]}"
  fetch_one "$t"
  mkdir -p "$dest_override"
  src="$(runner_path "$t")"
  lc="$(tool_bin_name "$t")"
  install -m 0755 "$src" "$dest_override/$lc"
  echo "fetch-tools: installed $lc -> $dest_override/$lc" >&2
  exit 0
fi

for t in "${tools_to_do[@]}"; do
  fetch_one "$t"
done
echo "fetch-tools: done -> $BIN_DIR" >&2
