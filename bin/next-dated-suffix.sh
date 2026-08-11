#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# §8: "Dated tags are NEVER overwritten; a same-day rebuild appends -2."
#
# That is a check against the registry, not an assumption that today is unused
# - a release re-run, a hotfix and a scheduled rebuild can all land on one date.
#
# The answer is RELEASE-WIDE. Every image x php is probed, and the first suffix
# unused by ALL of them wins. Deciding this per merge job would let runtime take
# -2 while cli takes -3, so one release would ship two different dated tags:
# exactly the silent inconsistency §8 exists to prevent, and the kind nobody
# notices until a consumer pins the pair.

date_str=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      require_arg "$1" "${2:-}"
      date_str="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: next-dated-suffix.sh --date YYYYMMDD" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$date_str" =~ ^[0-9]{8}$ ]]; then
  echo "error: --date is required and must be YYYYMMDD" >&2
  exit 2
fi

# Same guard as bin/size-check.sh's LARAOCI_MEASURE_CMD (L6): a seam that
# replaces the registry probe must not be reachable from production code, or
# "does this tag exist" becomes whatever the caller decided.
if [[ -n "${LARAOCI_TAG_EXISTS_CMD:-}" && "${LARAOCI_TEST:-0}" != "1" ]]; then
  echo "error: LARAOCI_TAG_EXISTS_CMD is a test-only seam; set LARAOCI_TEST=1 to use it." >&2
  exit 2
fi

tag_exists() {
  if [[ -n "${LARAOCI_TAG_EXISTS_CMD:-}" ]]; then
    bash -c "$LARAOCI_TAG_EXISTS_CMD" _ "$1"
  else
    docker buildx imagetools inspect "$1" >/dev/null 2>&1
  fi
}

registry="${LARAOCI_REGISTRY:-}"
if [[ -z "$registry" ]]; then
  registry="$("$YQ" -r '.defaults.registry' "$CONFIG")"
fi

default_debian="$("$YQ" -r '.defaults.debian' "$CONFIG")"
mapfile -t images < <("$YQ" -r '.images | keys | .[]' "$CONFIG")

php_versions=()
declare -A php_debian=()
while IFS= read -r v && IFS= read -r d; do
  [[ -z "$v" ]] && continue
  php_versions+=("$v")
  php_debian["$v"]="${d:-$default_debian}"
done < <("$YQ" -r '
  .php | to_entries | .[]
  | select(.value.status != "deprecated")
  | [.key, (.value.debian // "")]
  | .[]' "$CONFIG")

n=1
while :; do
  suffix="-${date_str}"
  ((n > 1)) && suffix="-${date_str}-${n}"

  taken=0
  for image in "${images[@]}"; do
    for php in "${php_versions[@]}"; do
      if tag_exists "${registry}/${image}:${php}-${php_debian[$php]}${suffix}"; then
        taken=1
        break 2
      fi
    done
  done

  ((taken == 0)) && break

  n=$((n + 1))
  # A hard stop rather than an unbounded loop against a registry. Reaching this
  # means something is republishing in a tight cycle, and a release should stop
  # and say so rather than mint a -47.
  if ((n > 20)); then
    echo "error: ${date_str} already has 20 dated releases - refusing to guess further" >&2
    exit 1
  fi
done

printf '%s\n' "$suffix"
