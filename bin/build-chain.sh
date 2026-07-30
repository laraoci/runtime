#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# Builds an image together with every ancestor it descends from, parents first,
# tagging each into the LOCAL Docker daemon.
#
# WHY THIS EXISTS (🧭 5, M2). `images/cli/Dockerfile` and its siblings begin
# `FROM ghcr.io/laraoci/runtime:<php>-<suite>` - a reference that exists in no
# registry until the release path of M4 pushes one, and that the PR path never
# creates because it builds with push=false. Every matrix leg is a separate job
# on a separate runner, so the `cli` leg has no runtime image anywhere unless it
# builds one first. This is that step, and it is the same command a developer
# runs locally, so the two paths cannot drift.
#
# THE BUILDER IS NOT INCIDENTAL. `docker/setup-buildx-action` creates a
# docker-container driver builder, which has its own store and CANNOT see images
# in the local daemon - a parent that was just `--load`ed into the daemon is
# invisible to it, and the child's FROM fails with a bare "not found" that reads
# like a registry problem. The `default` builder IS the daemon's BuildKit, so it
# resolves a local tag with no registry involved. Overridable for a caller that
# knows better, but the default is the whole point.
BUILDER="${LARAOCI_BUILDER:-default}"

image=""
php=""
dry_run=0
ancestors_only=0

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
    --dry-run)
      dry_run=1
      shift
      ;;
    # Build everything NAME stands on, but not NAME itself. This is what
    # .github/workflows/build.yml calls on the load path: the reusable workflow
    # builds the target through docker/build-push-action, with the labels and
    # the resolved base digest that only CI has, and needs the ancestors to
    # already exist in the daemon by the time it does. Asking for the target's
    # ancestors rather than for its parent by name keeps the graph walk in one
    # tested place instead of in workflow YAML, and makes the call a no-op for
    # the graph root with no conditional around it.
    --ancestors-only)
      ancestors_only=1
      shift
      ;;
    -h | --help)
      echo "usage: build-chain.sh --image NAME --php VERSION [--ancestors-only] [--dry-run]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$image" ]]; then
  echo "error: --image is required" >&2
  exit 2
fi

if [[ -z "$php" ]]; then
  echo "error: --php is required" >&2
  exit 2
fi

# The graph is validated FIRST, before anything else in the config is read.
# read_image_graph is what rejects a cycle, a dangling parent and an unsafe
# image name, so a config broken in one of those ways must say so rather than
# fail later on an unrelated missing key.
read_image_graph

if [[ -z "${IMAGE_PARENT[$image]+set}" ]]; then
  echo "error: '$image' is not an image in $CONFIG" >&2
  echo "       known images: ${IMAGE_NAMES[*]}" >&2
  exit 2
fi

# The Debian suite per supported PHP version, resolved the way bin/matrix.sh
# resolves it: a per-version `debian:` key overrides defaults.debian (§3.1), and
# a deprecated version is not built at all (§5 schema rules). One field per
# line, two reads per record - see the comment in bin/matrix.sh for why `@tsv`
# with IFS=$'\t' silently shifts a row whose optional field is empty.
default_debian="$(yq -r '.defaults.debian' "$CONFIG")"
declare -A php_debian=()
supported_php=()
while IFS= read -r v && IFS= read -r d; do
  [[ -z "$v" ]] && continue
  supported_php+=("$v")
  if [[ -n "$d" ]]; then
    php_debian["$v"]="$d"
  else
    php_debian["$v"]="$default_debian"
  fi
done < <(yq -r '
  .php | to_entries | .[]
  | select(.value.status != "deprecated")
  | [.key, (.value.debian // "")]
  | .[]' "$CONFIG")

# Validated in bash against the known set rather than by interpolating the value
# into a yq query - the reasoning bin/size-check.sh applies to --image.
if [[ -z "${php_debian[$php]+set}" ]]; then
  echo "error: '$php' is not a supported PHP version in $CONFIG" >&2
  echo "       supported: ${supported_php[*]}" >&2
  exit 2
fi

debian="${php_debian[$php]}"
if [[ -z "$debian" || "$debian" == "null" ]]; then
  echo "error: no Debian suite for PHP $php - set defaults.debian or php.\"$php\".debian in $CONFIG" >&2
  exit 1
fi

# Registry and identity in one read. Identity is NOT allowed to fall back to the
# Dockerfiles' ARG defaults: D8 exists because a UID that silently differs
# between images is the failure mode, so a config that does not state the
# identity fails here rather than letting a second source of truth exist.
mapfile -t defaults < <(yq -r '
  [.defaults.registry, .defaults.user.name, .defaults.user.uid, .defaults.user.gid] | .[]' "$CONFIG")
if ((${#defaults[@]} != 4)); then
  echo "error: $CONFIG does not define defaults.registry and defaults.user.{name,uid,gid}" >&2
  exit 1
fi
registry="${defaults[0]}"
user_name="${defaults[1]}"
user_uid="${defaults[2]}"
user_gid="${defaults[3]}"
for field in "${defaults[@]}"; do
  if [[ -z "$field" || "$field" == "null" ]]; then
    echo "error: $CONFIG leaves one of defaults.registry / defaults.user.* unset:" >&2
    echo "       registry=$registry name=$user_name uid=$user_uid gid=$user_gid" >&2
    exit 1
  fi
done

# The description label is read here, keyed by name, so the image name is never
# interpolated into a yq expression even though read_image_graph has already
# validated its shape. tests/structure/builder.yaml asserts this label, so a
# locally built image has to carry it exactly as a CI-built one does.
declare -A image_description=()
while IFS= read -r name && IFS= read -r desc; do
  [[ -z "$name" ]] && continue
  image_description["$name"]="$desc"
done < <(yq -r '
  .images | to_entries | .[]
  | [.key, (.value.description // "")]
  | .[]' "$CONFIG")

# Ancestors first. read_image_graph has already rejected a dangling parent and a
# cycle, so walking up cannot loop and cannot fall off the graph.
chain=()
cur="$image"
while [[ -n "$cur" ]]; do
  chain=("$cur" ${chain[@]+"${chain[@]}"})
  cur="${IMAGE_PARENT[$cur]}"
done

if ((ancestors_only)); then
  chain=("${chain[@]:0:${#chain[@]}-1}")
  if ((${#chain[@]} == 0)); then
    echo "build-chain: '$image' is the graph root - no ancestors to build" >&2
    exit 0
  fi
fi

if ((dry_run == 0)) && ! command -v docker >/dev/null 2>&1; then
  echo "error: 'docker' not found." >&2
  exit 1
fi

for img in "${chain[@]}"; do
  dockerfile="${IMAGE_DOCKERFILE[$img]}"
  if [[ -z "$dockerfile" ]]; then
    echo "error: image '$img' has no dockerfile in $CONFIG" >&2
    exit 1
  fi

  ref="$registry/$img:$php-$debian"

  args=(
    --build-arg "PHP_VERSION=$php"
    --build-arg "DEBIAN_RELEASE=$debian"
    --build-arg "USER_NAME=$user_name"
    --build-arg "USER_UID=$user_uid"
    --build-arg "USER_GID=$user_gid"
  )

  # A child is pinned to the ref this loop tagged one iteration ago. The root
  # gets no PARENT_REF at all - its Dockerfile derives from the upstream php
  # image - and no BASE_DIGEST either: images/runtime/Dockerfile documents an
  # empty BASE_DIGEST as correct for a local build off the tag, and resolving
  # the real digest would put a registry round-trip in front of every offline
  # rebuild for the sake of one label. CI passes the resolved digest on the leg
  # that actually publishes the image.
  parent="${IMAGE_PARENT[$img]}"
  if [[ -n "$parent" ]]; then
    args+=(--build-arg "PARENT_REF=$registry/$parent:$php-$debian")
  fi

  args+=(--label "org.opencontainers.image.title=laraoci/$img")
  if [[ -n "${image_description[$img]:-}" ]]; then
    args+=(--label "org.opencontainers.image.description=${image_description[$img]}")
  fi

  if ((dry_run)); then
    printf 'build %s %s %s\n' "$img" "$dockerfile" "$ref"
    # Every entry is a flag followed by its value, so pairs print as pairs.
    for ((i = 0; i < ${#args[@]}; i += 2)); do
      printf '  %s %s\n' "${args[i]}" "${args[i + 1]}"
    done
    continue
  fi

  if [[ ! -f "$dockerfile" ]]; then
    echo "error: $dockerfile does not exist (image '$img')" >&2
    exit 1
  fi

  echo "build-chain: $img -> $ref" >&2
  docker buildx build \
    --builder "$BUILDER" \
    --load \
    --file "$dockerfile" \
    --tag "$ref" \
    "${args[@]}" \
    .
done
