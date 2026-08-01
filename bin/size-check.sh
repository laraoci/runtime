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
php=""
explicit_ref=""

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
    --php)
      require_arg "$1" "${2:-}"
      php="$2"
      shift 2
      ;;
    --ref)
      require_arg "$1" "${2:-}"
      explicit_ref="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: size-check.sh [--report] [--image NAME] [--php VERSION] [--ref IMAGE_REF]" >&2
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

registry="$("$YQ" -r '.defaults.registry' "$CONFIG")"

mapfile -t budget_images < <("$YQ" -r '.size_budgets | keys | .[]' "$CONFIG")

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

# THE RELEASE PATH MEASURES A DIGEST, and a digest cannot be derived from
# config/images.yml - it is whatever BuildKit produced. --ref takes it verbatim
# and skips the tag derivation below entirely.
#
# It requires --image because a digest names exactly one image: measuring all
# six budgets against one reference would print five rows that are wrong and one
# that happens not to be.
#
# The INSTRUMENT is deliberately unchanged. size_budgets was frozen with
# `docker save | gzip | wc -c` (D17, docs/size-report-m1..m3.md); summing
# layers[].size from the registry manifest is arguably the truer compressed
# size, but it is a DIFFERENT number, and enforcing a budget set by one
# instrument with a measurement from another turns a clean build into a
# spurious release block. The ref changes; the yardstick does not.
if [[ -n "$explicit_ref" && -z "$image_filter" ]]; then
  echo "error: --ref requires --image - a reference names one image, not the set" >&2
  exit 2
fi

# CI sets LARAOCI_TAG to `<php>-<debian>` for the leg it just built, and that
# always wins. With it unset the tag is DERIVED the same way - it used to
# default to the literal `local`, a tag nothing in this repository ever
# produces, so every invocation without LARAOCI_TAG measured an image that
# could not exist and died on `docker save`.
tag=""
if [[ -z "$explicit_ref" ]]; then
  tag="${LARAOCI_TAG:-}"
  # Nested inside the --ref guard, not merged with it: --ref bypasses tag
  # derivation entirely, but LARAOCI_TAG still outranks derivation whenever a
  # tag IS being derived. Flattening these into one condition makes the
  # derivation below overwrite the tag CI just built.
  if [[ -z "$tag" ]]; then
    default_debian="$("$YQ" -r '.defaults.debian // ""' "$CONFIG")"

    if [[ -z "$php" ]]; then
      php="$("$YQ" -r '.php // {} | to_entries | .[] | select(.value.default == true) | .key' "$CONFIG")"
      if [[ -z "$php" || "$php" == "null" ]]; then
        echo "error: no PHP version carries 'default: true' in $CONFIG" >&2
        echo "       pass --php, or set LARAOCI_TAG to the tag to measure" >&2
        exit 2
      fi
    fi

    # The §3.1 per-version override, applied exactly as bin/build-chain.sh
    # applies it, so the tag measured here is the tag that was built.
    debian="$("$YQ" -r ".php.\"$php\".debian // \"\"" "$CONFIG")"
    [[ -z "$debian" || "$debian" == "null" ]] && debian="$default_debian"
    if [[ -z "$debian" ]]; then
      echo "error: no Debian suite for PHP $php in $CONFIG" >&2
      exit 2
    fi

    tag="$php-$debian"
  fi
fi

printf '%-12s %10s %10s %10s  %s\n' "IMAGE" "BUDGET_MB" "ACTUAL_MB" "DELTA_MB" "STATUS"
fail=0
missing=0
for image in "${budget_images[@]}"; do
  [[ -n "$image_filter" && "$image" != "$image_filter" ]] && continue
  budget_mb="$(IMAGE="$image" "$YQ" -r '.size_budgets[strenv(IMAGE)]' "$CONFIG")"
  if [[ -n "$explicit_ref" ]]; then
    ref="$explicit_ref"
  else
    ref="$registry/$image:$tag"
  fi

  # An image that is not in the daemon cannot be measured, and `docker save` on
  # a missing ref aborts the whole run under errexit - so a single unbuilt image
  # used to take the entire report down. That is not hypothetical: size_budgets
  # carries `queue` and `scheduler`, which have no Dockerfile until M3, so a
  # local run over the full set could never complete.
  #
  # Reported rather than skipped silently, and it still fails the ENFORCING path
  # (no --report): a size that was never measured must not read as a pass. The
  # advisory path (--report, what CI and `make sizes` use) prints the row and
  # carries on. Never fires under the measure seam, which does not touch docker.
  if [[ -z "${LARAOCI_MEASURE_CMD:-}" ]] &&
    command -v docker >/dev/null 2>&1 &&
    ! docker image inspect "$ref" >/dev/null 2>&1; then
    printf '%-12s %10s %10s %10s  %s\n' \
      "$image" "$(fmt_mb $((budget_mb * 100)))" "-" "-" "MISSING"
    missing=1
    ((report)) || fail=1
    continue
  fi

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

if ((missing)); then
  if [[ -n "$explicit_ref" ]]; then
    echo "note: MISSING means '$explicit_ref' is not in the local daemon." >&2
    echo "      the release path pulls the pushed digest before measuring it." >&2
  else
    echo "note: MISSING rows are images not in the local daemon at tag '$tag'." >&2
    echo "      build one with: bin/build-chain.sh --image <name> --php ${php:-<version>}" >&2
  fi
fi

((report)) && exit 0
exit "$fail"
