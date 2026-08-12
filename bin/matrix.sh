#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

php_filter=""
image_filter=""
platform_filter=""
depth_filter=""
include_deprecated=0

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
    --depth)
      require_arg "$1" "${2:-}"
      depth_filter="$2"
      shift 2
      ;;
    --include-deprecated)
      include_deprecated=1
      shift
      ;;
    -h | --help)
      echo "usage: matrix.sh [--php V] [--image NAME] [--platform P] [--depth N] [--include-deprecated]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# The PHP versions this invocation builds, in file order, each with the Debian
# suite it builds against - `supported` only unless --include-deprecated says
# otherwise. A per-version `debian:` key overrides defaults.debian - the §3.1
# transition mechanism, unset in normal operation (spec §271).
default_debian="$("$YQ" -r '.defaults.debian' "$CONFIG")"
php_versions=()
declare -A php_debian=()

# §13: `deprecated` stops the SCHEDULED rebuild, which is what this default
# serves - rebuild.yml never passes the flag, so a deprecated version cannot
# reach a cron-built leg. It does NOT forbid a release an operator explicitly
# asked for: --include-deprecated is reachable only from a human's
# workflow_dispatch, and even then the rolling-tag freeze still holds, because
# that is enforced in release.yml's repoint job and in bin/release-tags.sh
# rather than here.
status_filter='select(.value.status != "deprecated")'
if ((include_deprecated == 1)); then
  status_filter='.'
fi

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
done < <("$YQ" -r "
  .php | to_entries | .[] | ${status_filter}
  | [.key, (.value.debian // \"\")]
  | .[]" "$CONFIG")

read_image_graph

# platform -> native runner label. Read once; a leg's runner is a property of
# its platform, not of its image, so there is no per-image override to merge.
declare -A platform_runner=()
while IFS= read -r p && IFS= read -r r; do
  [[ -z "$p" ]] && continue
  platform_runner["$p"]="$r"
done < <("$YQ" -r '
  .defaults.runners // {} | to_entries | .[]
  | [.key, .value] | .[]' "$CONFIG")

# Distance from the graph root. read_image_graph has already rejected dangling
# parents and cycles, so this walk terminates.
image_depth() {
  local img="$1" d=0 p
  p="${IMAGE_PARENT[$img]}"
  while [[ -n "$p" ]]; do
    d=$((d + 1))
    p="${IMAGE_PARENT[$p]}"
  done
  printf '%s' "$d"
}

# Platform defaults are read once; a per-image override arrives in the graph.
mapfile -t default_platforms < <("$YQ" -r '.defaults.platforms | .[]' "$CONFIG")

legs=()
for php in "${php_versions[@]}"; do
  [[ -n "$php_filter" && "$php" != "$php_filter" ]] && continue
  debian="${php_debian[$php]}"
  for img in "${IMAGE_ORDER[@]}"; do
    [[ -n "$image_filter" && "$img" != "$image_filter" ]] && continue
    dockerfile="${IMAGE_DOCKERFILE[$img]}"
    parent="${IMAGE_PARENT[$img]}"
    depth="$(image_depth "$img")"
    [[ -n "$depth_filter" && "$depth" != "$depth_filter" ]] && continue
    if [[ -n "${IMAGE_PLATFORMS[$img]}" ]]; then
      IFS=',' read -r -a platforms <<<"${IMAGE_PLATFORMS[$img]}"
    else
      platforms=("${default_platforms[@]}")
    fi
    for plat in "${platforms[@]}"; do
      [[ -n "$platform_filter" && "$plat" != "$platform_filter" ]] && continue
      runner="${platform_runner[$plat]:-}"
      if [[ -z "$runner" ]]; then
        echo "error: no runner for platform '$plat' in $CONFIG" >&2
        echo "       add it under defaults.runners - a default here would build" >&2
        echo "       the leg under emulation and publish it as native (D3a)" >&2
        exit 1
      fi
      legs+=("$(jq -nc \
        --arg php "$php" --arg image "$img" --arg platform "$plat" \
        --arg dockerfile "$dockerfile" --arg debian "$debian" \
        --arg runner "$runner" --arg parent "$parent" --argjson depth "$depth" \
        '{php: $php, image: $image, platform: $platform, dockerfile: $dockerfile,
          debian: $debian, runner: $runner, parent: $parent, depth: $depth}')")
    done
  done
done

if ((${#legs[@]} == 0)); then
  echo '{"include":[]}'
  exit 0
fi

printf '%s\n' "${legs[@]}" | jq -sc '{include: .}'
