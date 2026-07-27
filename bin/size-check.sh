#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# Budget unit. The spec (§5/D17) states "compressed, MB". We treat MB as
# 1,000,000 bytes. The measurement (docker save | gzip) only APPROXIMATES the
# registry-compressed size, so the number is a consistent yardstick rather than
# a canonical one; M1 (LOCI-021) re-freezes the budgets against this exact tool.
readonly MB=1000000

report=0
image_filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      report=1
      shift
      ;;
    --image)
      image_filter="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: size-check.sh [--report] [--image NAME]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# Measure compressed bytes for an image ref. Overridable for tests.
measure() {
  local ref="$1"
  if [[ -n "${LARAOCI_MEASURE_CMD:-}" ]]; then
    bash -c "$LARAOCI_MEASURE_CMD" _ "$ref"
  else
    docker save "$ref" | gzip -c | wc -c
  fi
}

registry="$(yq -r '.defaults.registry' "$CONFIG")"
tag="${LARAOCI_TAG:-local}"

mapfile -t budget_images < <(yq -r '.size_budgets | keys | .[]' "$CONFIG")

printf '%-12s %10s %10s %10s  %s\n' "IMAGE" "BUDGET_MB" "ACTUAL_MB" "DELTA_MB" "STATUS"
fail=0
for image in "${budget_images[@]}"; do
  [[ -n "$image_filter" && "$image" != "$image_filter" ]] && continue
  budget_mb="$(yq -r ".size_budgets.\"$image\"" "$CONFIG")"
  ref="$registry/$image:$tag"
  actual_bytes="$(measure "$ref")"
  actual_mb=$((actual_bytes / MB))
  delta_mb=$((actual_mb - budget_mb))
  status="ok"
  if ((actual_bytes > budget_mb * MB)); then
    status="OVER"
    fail=1
  fi
  printf '%-12s %10d %10d %10d  %s\n' "$image" "$budget_mb" "$actual_mb" "$delta_mb" "$status"
done

((report)) && exit 0
exit "$fail"
