#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Runs container-structure-test against tests/structure/<image>.yaml.
#
# An image with no config is a deliberate no-op rather than an error: M1 ships
# only runtime, and M2/M3 gain coverage simply by adding a file - no CI edit.
#
# --ref is OPTIONAL. CI passes it explicitly because only CI knows the reference
# it just built - on the release path that is a registry ref with a digest, which
# cannot be derived from anything here. Locally there is no such thing: a
# developer has whatever `bin/build-chain.sh` tagged into their daemon, so an
# omitted --ref is derived the same way build-chain.sh composes that tag, from
# the same config. Nothing hardcodes the registry or the suite.

image=""
ref=""
php=""
config_dir="tests/structure"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      require_arg "$1" "${2:-}"
      image="$2"
      shift 2
      ;;
    --ref)
      require_arg "$1" "${2:-}"
      ref="$2"
      shift 2
      ;;
    --php)
      require_arg "$1" "${2:-}"
      php="$2"
      shift 2
      ;;
    --config-dir)
      require_arg "$1" "${2:-}"
      config_dir="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: structure-test.sh --image NAME [--ref IMAGE_REF] [--php VERSION] [--config-dir DIR]" >&2
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

config="$config_dir/$image.yaml"
if [[ ! -f "$config" ]]; then
  echo "structure-test: no config at $config - nothing to assert for '$image'"
  exit 0
fi

# Deriving the ref happens HERE, after the no-op check, and not at argument
# parsing time. An image with no config asserts nothing, so it must not need yq,
# a readable config/images.yml or a valid PHP version to report that.
if [[ -z "$ref" ]]; then
  require_mikefarah_yq

  # The same two reads bin/build-chain.sh makes, so a locally built tag and the
  # ref tested here cannot disagree. A per-version `debian:` key overrides
  # defaults.debian (§3.1); an absent one falls back.
  registry="$(yq -r '.defaults.registry' "$CONFIG")"
  if [[ -z "$registry" || "$registry" == "null" ]]; then
    echo "error: $CONFIG does not define defaults.registry" >&2
    exit 1
  fi

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

  # No --php means the version that backs :latest - the one a developer building
  # by hand is most likely to have in their daemon.
  if [[ -z "$php" ]]; then
    php="$(yq -r '.php | to_entries | .[] | select(.value.default == true) | .key' "$CONFIG")"
    if [[ -z "$php" || "$php" == "null" ]]; then
      echo "error: no PHP version carries 'default: true' in $CONFIG - pass --php" >&2
      exit 1
    fi
  fi

  # Checked in bash against the known set rather than interpolated into a yq
  # query - the reasoning bin/size-check.sh and bin/build-chain.sh both apply.
  if [[ -z "${php_debian[$php]+set}" ]]; then
    echo "error: '$php' is not a supported PHP version in $CONFIG" >&2
    echo "       supported: ${supported_php[*]}" >&2
    exit 2
  fi

  ref="$registry/$image:$php-${php_debian[$php]}"
  echo "structure-test: testing $ref"

  # The image is built locally by bin/build-chain.sh and exists in no registry
  # until M4 publishes one (D27), so a missing tag would otherwise surface as a
  # failed pull that reads like a registry outage rather than "you have not
  # built this yet".
  #
  # Skipped when LARAOCI_CST_CMD is set: that variable means "do not run the real
  # checker", so what the real daemon holds is irrelevant - and the tests would
  # otherwise have to build an image to assert on a string.
  if [[ -z "${LARAOCI_CST_CMD:-}" ]] &&
    command -v docker >/dev/null 2>&1 &&
    ! docker image inspect "$ref" >/dev/null 2>&1; then
    echo "error: $ref is not in the local daemon" >&2
    echo "       build it first: bin/build-chain.sh --image $image --php $php" >&2
    exit 1
  fi
fi

# The inherited contract (§6) runs on EVERY image alongside its own config, so
# that a regression introduced IN a descendant - a stray USER root, a package
# that drags Ghostscript back in, an entrypoint a COPY overwrote - fails on that
# descendant's own leg instead of being invisible because only `runtime` was
# ever asserted. container-structure-test accepts --config repeatedly and runs
# each file, so the two compose without either knowing about the other.
#
# It rides ON the per-image config rather than applying by itself. That keeps
# "an image gains coverage by adding a file" literally true, keeps an image with
# no file the announced no-op above, and leaves a future variant that
# legitimately breaks the common contract - a -slim image without imagick
# (LOCI-056) - able to opt out by not having a config, rather than needing a
# skip mechanism invented here on speculation.
configs=()
shared="$config_dir/_common.yaml"
if [[ -f "$shared" ]]; then
  configs+=(--config "$shared")
fi
configs+=(--config "$config")

# THE PINNED CHECKER, not whatever is on PATH. bin/fetch-tools.sh ensures the
# tools.env-pinned version is present, verifies its SHA-256 and prints its path
# - the same idiom lint.yml and tests/smoke/run.sh already use for bats.
#
# This used to resolve `container-structure-test` through PATH, so a machine with
# its own copy installed ran a DIFFERENT version from CI and neither run said so.
# The tool decides whether an image passes; silently disagreeing about which tool
# that is defeats the point of pinning everything else.
runner="${LARAOCI_CST_CMD:-}"
if [[ -z "$runner" ]]; then
  runner="$("$SCRIPT_DIR/fetch-tools.sh" --path container-structure-test)"
fi

if ! command -v "$runner" >/dev/null 2>&1; then
  echo "error: '$runner' not found. Run: make tools" >&2
  exit 1
fi

exec "$runner" test --image "$ref" "${configs[@]}"
