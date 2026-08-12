#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# §13's state transition, as one command, because it has THREE effects and a
# human doing it by hand does two of them.
#
#   1. the scheduled rebuild stops building it     - bin/matrix.sh's filter
#   2. the rolling tag FREEZES                     - release.yml's repoint
#   3. its dated tags stay forever, and the freeze
#      DATE is stated to consumers                 - deprecated_on, below
#
# Effects 1 and 2 follow from `status`. Effect 3 is why `deprecated_on` exists:
# without a date, "the rolling tag is frozen" is a claim with no way to tell how
# stale the image behind it is, and the README's supported-version table would
# have to be hand-typed - which is the drift LOCI-053 exists to prevent.
#
# THE TRAP THIS GUARDS (M5 trap 2): a half-deprecation that stops the rebuild
# but leaves the rolling tag live is WORSE than no deprecation, because the tag
# then points at an image that will never be patched again while the docs still
# imply it is current. The three effects move together or not at all, so this
# script refuses any transition that could only deliver some of them.

usage() {
  echo "usage: deprecate.sh --php V --on YYYY-MM-DD" >&2
}

php=""
on=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php)
      require_arg "$1" "${2:-}"
      php="$2"
      shift 2
      ;;
    --on)
      require_arg "$1" "${2:-}"
      on="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$php" || -z "$on" ]]; then
  echo "error: --php and --on are required" >&2
  usage
  exit 2
fi

# ISO 8601, checked rather than trusted: this string is rendered verbatim into
# the README and the docs site as "frozen on ...", and a locale-shaped date
# there is a claim consumers read wrong in both directions.
if [[ ! "$on" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "error: --on must be YYYY-MM-DD, got '$on'" >&2
  exit 2
fi

# strenv, not interpolation: a version string reaches a yq path expression.
status="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].status // ""' "$CONFIG")"
if [[ -z "$status" ]]; then
  echo "error: '$php' is not a PHP version in $CONFIG" >&2
  exit 2
fi

if [[ "$status" == "deprecated" ]]; then
  frozen="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].deprecated_on // "an unrecorded date"' "$CONFIG")"
  echo "note: $php is already deprecated (frozen ${frozen}); nothing to do" >&2
  exit 0
fi

# EFFECT 2 WOULD APPLY TO :latest. `default: true` is what backs :latest (§8),
# so deprecating that version freezes the tag most consumers pull while the
# catalog still lists it. Promote a new default first, deliberately, in its own
# reviewed change.
is_default="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].default // false' "$CONFIG")"
if [[ "$is_default" == "true" ]]; then
  echo "error: $php carries 'default: true' and backs :latest - refusing to deprecate it" >&2
  echo "       move 'default: true' to a supported version first, in its own change," >&2
  echo "       or :latest freezes along with it (§8, §13)" >&2
  exit 1
fi

# An empty supported set is a matrix of zero legs, and every workflow in this
# repository would go green while building nothing at all - the same class of
# silent success §9.3 is written against.
remaining="$(PHP="$php" "$YQ" -r '
  [.php | to_entries | .[]
   | select(.value.status != "deprecated")
   | select(.key != strenv(PHP))] | length' "$CONFIG")"
if ((remaining < 1)); then
  echo "error: deprecating $php would leave zero supported versions" >&2
  echo "       the build matrix would be empty and every workflow would pass" >&2
  exit 1
fi

# The comment census, taken BEFORE the edit. mikefarah/yq preserves comments on
# a targeted assignment, but "preserves" is a property of a version of a tool,
# and $CONFIG carries the runner pinning, the budget formula and its
# measurements. A tool that quietly ate them would be found at the next review
# rather than here.
comments_before="$(grep -c '^[[:space:]]*#' "$CONFIG")"
backup="$(mktemp)"
cp "$CONFIG" "$backup"

PHP="$php" ON="$on" "$YQ" -i '
  .php[strenv(PHP)].status = "deprecated" |
  .php[strenv(PHP)].deprecated_on = strenv(ON)' "$CONFIG"

comments_after="$(grep -c '^[[:space:]]*#' "$CONFIG")"
if [[ "$comments_before" != "$comments_after" ]]; then
  cp "$backup" "$CONFIG"
  rm -f "$backup"
  echo "error: the edit lost $((comments_before - comments_after)) comment lines from $CONFIG" >&2
  echo "       $CONFIG has been restored. This yq version does not round-trip" >&2
  echo "       this file's comments; make the two-line edit by hand instead." >&2
  exit 1
fi
rm -f "$backup"

cat >&2 <<EOF
$php is now deprecated, frozen ${on}. All three §13 effects follow from this:

  1. the scheduled rebuild skips it       - bin/matrix.sh filters it out
  2. its rolling tags FREEZE              - release.yml's repoint filters it out
  3. its dated tags remain forever, and
     ${on} is now the stated freeze date  - rendered by bin/docs-gen.sh

Next, in this same change:

  bin/docs-gen.sh          regenerate the README block and the docs site
  git add config/images.yml README.md docs-site/content

A deliberate release of $php can still publish: dispatch release.yml with
include_deprecated=true. Its rolling tags still will not move - that freeze is
enforced in the repoint job, which that input does not reach.
EOF
