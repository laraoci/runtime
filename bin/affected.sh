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
changed=()
if [[ -n "$base" ]]; then
  mapfile -t changed < <(git diff --no-renames --name-only "$base")
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
    docs/* | tests/*) : ;; # documentation and tests never rebuild an image
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
