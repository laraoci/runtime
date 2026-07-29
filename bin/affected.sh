#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

base=""
as_json=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      require_arg "$1" "${2:-}"
      base="$2"
      shift 2
      ;;
    --json)
      as_json=1
      shift
      ;;
    -h | --help)
      echo "usage: affected.sh [--base REF] [--json]   (paths on stdin if --base absent)" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# Changed paths: from git (rename detection OFF so a rename splits into
# delete-old + add-new, both mapping to the same image; deletions included),
# or from stdin.
#
# THE ASSIGNMENT IS THE POINT, not the mapfile. `mapfile -t x < <(git diff …)`
# does not observe git's exit status and errexit does not reach into a process
# substitution, so an unresolvable base ref produced an empty list and a clean
# exit 0 - which pr.yml reads as "nothing is affected", skips every build leg,
# and still passes pr-required. A plain command substitution DOES trip errexit,
# and the explicit `if` reports which ref failed.
changed=()
if [[ -n "$base" ]]; then
  if ! changed_out="$(git diff --no-renames --name-only "$base")"; then
    echo "error: 'git diff $base' failed - cannot determine affected images" >&2
    echo "       is the base ref fetched? CI needs fetch-depth: 0" >&2
    exit 1
  fi
  # A truly empty diff is a legitimate answer (a docs-only PR), and must stay
  # distinct from the failure above. `mapfile <<<""` would yield one empty
  # element rather than none, so the guard is not cosmetic.
  if [[ -n "$changed_out" ]]; then
    mapfile -t changed <<<"$changed_out"
  fi
else
  mapfile -t changed
fi

read_image_graph

# parent -> children adjacency. Every parent is guaranteed to be a real image,
# because read_image_graph rejected dangling parents already.
declare -A children=()
for img in "${IMAGE_NAMES[@]}"; do children["$img"]=""; done
for img in "${IMAGE_NAMES[@]}"; do
  p="${IMAGE_PARENT[$img]}"
  [[ -n "$p" ]] && children["$p"]+="$img "
done

declare -A affected=()

add_all() {
  for i in "${IMAGE_NAMES[@]}"; do affected["$i"]=1; done
}

# BFS over descendants: the image itself plus everything that inherits from it.
add_with_descendants() {
  local -a queue=("$1")
  while ((${#queue[@]})); do
    local cur="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${affected[$cur]:-}" ]] && continue
    affected["$cur"]=1
    local c
    for c in ${children[$cur]}; do queue+=("$c"); done
  done
}

for path in "${changed[@]}"; do
  [[ -z "$path" ]] && continue
  case "$path" in
    # Documentation and the test inputs that only feed the bats job never
    # rebuild an image.
    docs/* | tests/unit/* | tests/fixtures/* | tests/probe/* | tests/stub/* | tests/bats/*) : ;;
    # The shared contract is passed to EVERY image's structure run alongside its
    # own config (bin/structure-test.sh), so editing it must rebuild the whole
    # graph. The fallback below already reaches that answer - "_common" is not
    # an image name, so it takes the be-conservative branch - but by accident.
    # Named here so the rebuild is a stated consequence of what the file is,
    # and so a future image called `common` cannot quietly narrow it to one leg.
    tests/structure/_common.yaml) add_all ;;
    # Any OTHER structure-test config runs only inside a build leg for its own
    # image, so editing one must build that image - and only that image, since
    # every image carries its own config (M4).
    tests/structure/*.yaml)
      name="${path#tests/structure/}"
      name="${name%.yaml}"
      if [[ -n "${IMAGE_PARENT[$name]+set}" ]]; then
        affected["$name"]=1
      else
        add_all # a config for an unknown image - be conservative
      fi
      ;;
    config/* | bin/* | .github/workflows/build.yml) add_all ;;
    images/*/*)
      name="${path#images/}"
      name="${name%%/*}"
      if [[ -n "${children[$name]+set}" ]]; then
        add_with_descendants "$name"
      else
        add_all # unknown image directory - be conservative
      fi
      ;;
    *) add_all ;; # unrecognised path - rebuild everything rather than miss one
  esac
done

result=()
for img in "${IMAGE_NAMES[@]}"; do
  [[ -n "${affected[$img]:-}" ]] && result+=("$img")
done

if ((as_json)); then
  # printf with zero arguments still emits one newline, which split("\n") turns
  # into two empty strings - both filtered out. So the empty case needs no
  # special handling and one jq does the whole job.
  printf '%s\n' "${result[@]+"${result[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))'
  exit 0
fi

((${#result[@]})) && printf '%s\n' "${result[@]}"
exit 0
