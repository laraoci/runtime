#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# The six §8 tag forms for ONE image x php, printed one reference per line.
#
#   PHP minor      :8.4                        rolling
#   PHP + Debian   :8.4-trixie                 rolling
#   Dated          :8.4-trixie-20260801        IMMUTABLE
#   Patch + dated  :8.4.10-trixie-20260801     IMMUTABLE
#   Digest         @sha256:...                 inherent - the caller has it
#   :latest        default PHP version ONLY    rolling
#
# The split between rolling and immutable is not cosmetic: LOCI-046 writes the
# immutable forms per merge job and the rolling forms only after the WHOLE
# matrix has passed, so the two sets are requested separately and never by
# accident together.
#
# The date is NEVER read here. --dated-suffix is required for the immutable
# forms because the release computes it once and passes it to all 18 merge jobs
# (🧭 2); a clock read in this script would let two legs disagree about which
# day it is, and a release would ship two dated tags.

usage() {
  echo "usage: release-tags.sh --image NAME --php V --kind rolling|immutable|all" >&2
  echo "                       [--dated-suffix -YYYYMMDD[-N]] [--patch X.Y.Z]" >&2
  echo "                       [--include-deprecated]" >&2
}

image=""
php=""
kind=""
dated_suffix=""
patch=""
include_deprecated=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      require_arg "$1" "${2:-}"
      image="$2"
      shift 2
      ;;
    --php)
      require_arg "$1" "${2:-}"
      php="$2"
      shift 2
      ;;
    --kind)
      require_arg "$1" "${2:-}"
      kind="$2"
      shift 2
      ;;
    --dated-suffix)
      require_arg "$1" "${2:-}"
      dated_suffix="$2"
      shift 2
      ;;
    --patch)
      require_arg "$1" "${2:-}"
      patch="$2"
      shift 2
      ;;
    --include-deprecated)
      include_deprecated=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$image" || -z "$php" || -z "$kind" ]]; then
  echo "error: --image, --php and --kind are required" >&2
  usage
  exit 2
fi

case "$kind" in
  rolling | immutable | all) : ;;
  *)
    echo "error: --kind must be rolling, immutable or all" >&2
    exit 2
    ;;
esac

if [[ "$kind" != "rolling" && -z "$dated_suffix" ]]; then
  echo "error: --dated-suffix is required for the immutable forms" >&2
  echo "       the release computes it ONCE and passes it down; this script" >&2
  echo "       never reads a clock, so two legs cannot disagree about the date" >&2
  exit 2
fi

if [[ -n "$dated_suffix" && ! "$dated_suffix" =~ ^-[0-9]{8}(-[0-9]+)?$ ]]; then
  echo "error: --dated-suffix must look like -YYYYMMDD or -YYYYMMDD-N, got '$dated_suffix'" >&2
  exit 2
fi

# LARAOCI_REGISTRY is the dry-run seam: 🚦 Gate 2 runs the entire release path
# against a throwaway namespace, and every tag must follow it or the dry run
# writes real tags. Empty means the config, which is what a release uses.
registry="${LARAOCI_REGISTRY:-}"
if [[ -z "$registry" ]]; then
  registry="$("$YQ" -r '.defaults.registry' "$CONFIG")"
fi

# The image name is validated against the known set in bash rather than
# interpolated into a yq query - the reasoning bin/size-check.sh applies.
mapfile -t known_images < <("$YQ" -r '.images | keys | .[]' "$CONFIG")
found=0
for known in "${known_images[@]}"; do
  [[ "$known" == "$image" ]] && found=1
done
if ((found == 0)); then
  echo "error: '$image' is not an image in $CONFIG" >&2
  exit 2
fi

default_debian="$("$YQ" -r '.defaults.debian' "$CONFIG")"
declare -A php_debian=()
declare -A php_default=()

# §13. The default is `supported` only, so nothing reaches a deprecated
# version's tags by accident; --include-deprecated is the deliberate opt-in a
# human types on a workflow_dispatch, and the schedule never passes it.
status_filter='select(.value.status != "deprecated")'
if ((include_deprecated == 1)); then
  status_filter='.'
fi

while IFS= read -r v && IFS= read -r d && IFS= read -r def; do
  [[ -z "$v" ]] && continue
  php_debian["$v"]="${d:-$default_debian}"
  php_default["$v"]="$def"
done < <("$YQ" -r "
  .php | to_entries | .[] | ${status_filter}
  | [.key, (.value.debian // \"\"), (.value.default // false | tostring)]
  | .[]" "$CONFIG")

# THE REQUESTED VERSION'S STATUS, READ DIRECTLY - not looked up in the filtered
# map above, because the map cannot distinguish "no such version" from "filtered
# out", and those two need different answers. Deriving the refusal from the map
# produced a message that was actively misleading: asking for a deprecated
# version's ROLLING tags without the flag was refused with "not a supported PHP
# version - pass --include-deprecated", which invites the caller to retry with a
# flag that would refuse them again, for a different and unstated reason.
requested_status="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].status // ""' "$CONFIG")"
if [[ -z "$requested_status" ]]; then
  echo "error: '$php' is not a PHP version in $CONFIG" >&2
  exit 2
fi

# THE ROLLING-TAG FREEZE (§13, effect 2), at the one place every rolling tag in
# this repository is minted. It is checked BEFORE the opt-in below and does not
# consult it, because --include-deprecated must never unlock this.
#
# A deprecated version keeps its dated tags forever and may still be published
# deliberately - a backport during a wind-down is a real thing to need - but
# :8.5, :8.5-trixie and :latest stop moving on the day it was deprecated, and
# stay stopped. A release path that could move them would make the freeze a
# convention rather than a mechanism, and the failure would be invisible: the
# rolling tag would keep resolving, and would keep pointing at an image nothing
# will ever patch again.
#
# The test is on `!= immutable`, not on `== rolling`: `--kind all` includes the
# rolling forms, so a check written against `rolling` alone would leak every one
# of them through the `all` door.
if [[ "$kind" != "immutable" && "$requested_status" == "deprecated" ]]; then
  frozen="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].deprecated_on // "an unrecorded date"' "$CONFIG")"
  echo "error: $php is deprecated - its rolling tags are frozen (${frozen}, §13)" >&2
  echo "       its dated tags remain available: --kind immutable" >&2
  exit 2
fi

if [[ -z "${php_debian[$php]+set}" ]]; then
  echo "error: '$php' is deprecated in $CONFIG (frozen $(PHP="$php" "$YQ" -r '.php[strenv(PHP)].deprecated_on // "on an unrecorded date"' "$CONFIG"))" >&2
  echo "       pass --include-deprecated for a deliberate release of it (§13);" >&2
  echo "       the scheduled rebuild never does" >&2
  exit 2
fi

debian="${php_debian[$php]}"

emit() { printf '%s/%s:%s\n' "$registry" "$image" "$1"; }

if [[ "$kind" == "rolling" || "$kind" == "all" ]]; then
  emit "$php"
  emit "${php}-${debian}"
  # :latest follows the DEFAULT version only (§8). Pointing the tag most
  # consumers pull at a version the project did not choose for them is the one
  # tagging mistake that reaches everybody at once.
  if [[ "${php_default[$php]}" == "true" ]]; then
    emit "latest"
  fi
fi

if [[ "$kind" == "immutable" || "$kind" == "all" ]]; then
  emit "${php}-${debian}${dated_suffix}"
  if [[ -n "$patch" ]]; then
    emit "${patch}-${debian}${dated_suffix}"
  fi
fi
