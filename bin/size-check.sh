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
      require_arg "$1" "${2:-}"
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

# LARAOCI_MEASURE_CMD runs an arbitrary string through `bash -c` on the same
# code path CI executes. It is a test seam and nothing else, so it now says so
# out loud rather than sitting in production code looking like a feature (L6).
if [[ -n "${LARAOCI_MEASURE_CMD:-}" && "${LARAOCI_TEST:-0}" != "1" ]]; then
  echo "error: LARAOCI_MEASURE_CMD is a test-only seam; set LARAOCI_TEST=1 to use it." >&2
  exit 2
fi

# Measure compressed bytes for an image ref. Overridable for tests, gated above.
measure() {
  local ref="$1"
  if [[ -n "${LARAOCI_MEASURE_CMD:-}" ]]; then
    bash -c "$LARAOCI_MEASURE_CMD" _ "$ref"
  else
    docker save "$ref" | gzip -c | wc -c
  fi
}

# MB rendered to two decimal places without floating point: values are carried
# in hundredths of an MB. The pass/fail test below still compares exact bytes,
# so the printed number can never contradict STATUS (L1).
fmt_mb() {
  local hundredths="$1" sign=""
  if ((hundredths < 0)); then
    sign="-"
    hundredths=$((-hundredths))
  fi
  printf '%s%d.%02d' "$sign" $((hundredths / 100)) $((hundredths % 100))
}

registry="$(yq -r '.defaults.registry' "$CONFIG")"
tag="${LARAOCI_TAG:-local}"

mapfile -t budget_images < <(yq -r '.size_budgets | keys | .[]' "$CONFIG")

# A --image that matches no budget used to produce an empty loop and exit 0,
# so an image missing from size_budgets got NO size coverage and still reported
# green. The filter is validated against the known set instead - in bash, not in
# a yq expression, so the name is never interpolated into a query (M1).
if [[ -n "$image_filter" ]]; then
  found=0
  for image in "${budget_images[@]}"; do
    [[ "$image" == "$image_filter" ]] && found=1
  done
  if ((found == 0)); then
    echo "error: no size budget for image '$image_filter' in $CONFIG" >&2
    echo "       known images: ${budget_images[*]}" >&2
    exit 2
  fi
fi

printf '%-12s %10s %10s %10s  %s\n' "IMAGE" "BUDGET_MB" "ACTUAL_MB" "DELTA_MB" "STATUS"
fail=0
for image in "${budget_images[@]}"; do
  [[ -n "$image_filter" && "$image" != "$image_filter" ]] && continue
  budget_mb="$(yq -r ".size_budgets.\"$image\"" "$CONFIG")"
  ref="$registry/$image:$tag"
  actual_bytes="$(measure "$ref")"

  actual_h=$((actual_bytes * 100 / MB))
  budget_h=$((budget_mb * 100))
  delta_h=$((actual_h - budget_h))

  status="ok"
  if ((actual_bytes > budget_mb * MB)); then
    status="OVER"
    fail=1
  fi
  printf '%-12s %10s %10s %10s  %s\n' \
    "$image" "$(fmt_mb "$budget_h")" "$(fmt_mb "$actual_h")" "$(fmt_mb "$delta_h")" "$status"
done

((report)) && exit 0
exit "$fail"
