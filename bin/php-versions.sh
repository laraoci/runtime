#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# THE ONE PLACE A WORKFLOW ASKS "WHICH PHP VERSIONS". It exists because the
# `select(.value.status != "deprecated")` filter was written out by hand in three
# separate `run:` bodies in release.yml, and one of those - the repoint's - IS
# §13's rolling-tag freeze. A filter that load-bearing should not be a string
# duplicated in YAML that no unit test can see; here it is one script with tests.
#
# The scripts that also read the debian suite and the default flag
# (bin/matrix.sh, bin/release-tags.sh, bin/next-dated-suffix.sh) keep their own
# reads - they need more fields, and rewriting three working release-path
# scripts is not a change this milestone should make. They gain the same
# --include-deprecated flag instead, and tests/unit pins each one.

include_deprecated=0
with_status=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-deprecated)
      include_deprecated=1
      shift
      ;;
    --with-status)
      with_status=1
      shift
      ;;
    -h | --help)
      echo "usage: php-versions.sh [--include-deprecated] [--with-status]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

filter='.'
if ((include_deprecated == 0)); then
  filter='select(.value.status != "deprecated")'
fi

if ((with_status == 1)); then
  "$YQ" -r "
    .php | to_entries | .[] | ${filter}
    | [.key, (.value.status // \"supported\"), (.value.deprecated_on // \"\")]
    | join(\"\t\")" "$CONFIG"
else
  "$YQ" -r ".php | to_entries | .[] | ${filter} | .key" "$CONFIG"
fi
