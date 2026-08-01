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
    --php)
      require_arg "$1" "${2:-}"
      php_filter="$2"
      shift 2
      ;;
    --image)
      require_arg "$1" "${2:-}"
      image_filter="$2"
      shift 2
      ;;
    --platform)
      require_arg "$1" "${2:-}"
      platform_filter="$2"
      shift 2
      ;;
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

# Supported (non-deprecated) PHP versions, in file order, each with the Debian
# suite it builds against. A per-version `debian:` key overrides defaults.debian
# - the §3.1 transition mechanism, unset in normal operation (spec §271).
default_debian="$("$YQ" -r '.defaults.debian' "$CONFIG")"
php_versions=()
declare -A php_debian=()
# One field per line, two reads per record - the same idiom as
# read_image_graph, and for the same reason. `@tsv` with IFS=$'\t' would work
# here today only by accident: the empty field is the LAST one and read strips
# trailing IFS whitespace. Add a third column, or reorder these two, and
# adjacent-tab collapsing silently shifts every value one slot left.
while IFS= read -r v && IFS= read -r d; do
  [[ -z "$v" ]] && continue
  php_versions+=("$v")
  if [[ -n "$d" ]]; then
    php_debian["$v"]="$d"
  else
    php_debian["$v"]="$default_debian"
  fi
done < <("$YQ" -r '
  .php | to_entries | .[]
  | select(.value.status != "deprecated")
  | [.key, (.value.debian // "")]
  | .[]' "$CONFIG")

read_image_graph

# Platform defaults are read once; a per-image override arrives in the graph.
mapfile -t default_platforms < <("$YQ" -r '.defaults.platforms | .[]' "$CONFIG")

legs=()
for php in "${php_versions[@]}"; do
  [[ -n "$php_filter" && "$php" != "$php_filter" ]] && continue
  debian="${php_debian[$php]}"
  for img in "${IMAGE_ORDER[@]}"; do
    [[ -n "$image_filter" && "$img" != "$image_filter" ]] && continue
    dockerfile="${IMAGE_DOCKERFILE[$img]}"
    if [[ -n "${IMAGE_PLATFORMS[$img]}" ]]; then
      IFS=',' read -r -a platforms <<<"${IMAGE_PLATFORMS[$img]}"
    else
      platforms=("${default_platforms[@]}")
    fi
    for plat in "${platforms[@]}"; do
      [[ -n "$platform_filter" && "$plat" != "$platform_filter" ]] && continue
      legs+=("$(jq -nc \
        --arg php "$php" --arg image "$img" --arg platform "$plat" \
        --arg dockerfile "$dockerfile" --arg debian "$debian" \
        '{php: $php, image: $image, platform: $platform, dockerfile: $dockerfile, debian: $debian}')")
    done
  done
done

if ((${#legs[@]} == 0)); then
  echo '{"include":[]}'
  exit 0
fi

printf '%s\n' "${legs[@]}" | jq -sc '{include: .}'
