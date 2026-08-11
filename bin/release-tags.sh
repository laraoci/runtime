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
}

image=""
php=""
kind=""
dated_suffix=""
patch=""

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
while IFS= read -r v && IFS= read -r d && IFS= read -r def; do
  [[ -z "$v" ]] && continue
  php_debian["$v"]="${d:-$default_debian}"
  php_default["$v"]="$def"
done < <("$YQ" -r '
  .php | to_entries | .[]
  | select(.value.status != "deprecated")
  | [.key, (.value.debian // ""), (.value.default // false | tostring)]
  | .[]' "$CONFIG")

if [[ -z "${php_debian[$php]+set}" ]]; then
  echo "error: '$php' is not a supported PHP version in $CONFIG" >&2
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
