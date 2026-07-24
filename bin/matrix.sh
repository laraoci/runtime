#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

php_filter=""
image_filter=""
platform_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php) php_filter="$2"; shift 2 ;;
    --image) image_filter="$2"; shift 2 ;;
    --platform) platform_filter="$2"; shift 2 ;;
    -h | --help)
      echo "usage: matrix.sh [--php V] [--image NAME] [--platform P]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
    esac
done

# Supported (non-deprecated) PHP versions, in file order.
mapfile -t php_versions < <(
  yq -r '.php | to_entries | .[] | select(.value.status != "deprecated") | .key' "$CONFIG"
)

# Image names and their parents.
mapfile -t image_names < <(yq -r '.images | keys | .[]' "$CONFIG")
declare -A parent=()
for img in "${image_names[@]}"; do
  parent["$img"]="$(yq -r ".images.\"$img\".parent // \"\"" "$CONFIG")"
done

# Topological sort by parent (Kahn-style): emit an image once its parent has
# been emitted. Build order must never be hand-maintained.
sorted=()
declare -A emitted=()
while ((${#sorted[@]} < ${#image_names[@]})); do
  progress=0
  for img in "${image_names[@]}"; do
    [[ -n "${emitted[$img]:-}" ]] && continue
    p="${parent[$img]}"
    if [[ -z "$p" || -n "${emitted[$p]:-}" ]]; then
      sorted+=("$img")
      emitted["$img"]=1
      progress=1
    fi
  done
  ((progress)) || {
    echo "error: cycle or dangling parent in images graph" >&2
    exit 1
  }
done

legs=()
for php in "${php_versions[@]}"; do
  [[ -n "$php_filter" && "$php" != "$php_filter" ]] && continue
  for img in "${sorted[@]}"; do
    [[ -n "$image_filter" && "$img" != "$image_filter" ]] && continue
    mapfile -t platforms < <(
      yq -r ".images.\"$img\".platforms // .defaults.platforms | .[]" "$CONFIG"
    )
    for plat in "${platforms[@]}"; do
      [[ -n "$platform_filter" && "$plat" != "$platform_filter" ]] && continue
      legs+=("$(jq -nc \
        --arg php "$php" --arg image "$img" --arg platform "$plat" \
        '{php: $php, image: $image, platform: $platform}')")
    done
  done
done

if ((${#legs[@]} == 0)); then
  echo '{"include":[]}'
  exit 0
fi

printf '%s\n' "${legs[@]}" | jq -sc '{include: .}'
