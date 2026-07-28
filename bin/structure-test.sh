#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Runs container-structure-test against tests/structure/<image>.yaml.
#
# An image with no config is a deliberate no-op rather than an error: M1 ships
# only runtime, and M2/M3 gain coverage simply by adding a file - no CI edit.

image=""
ref=""
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
    --config-dir)
      require_arg "$1" "${2:-}"
      config_dir="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: structure-test.sh --image NAME --ref IMAGE_REF [--config-dir DIR]" >&2
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

if [[ -z "$ref" ]]; then
  echo "error: --ref is required" >&2
  exit 2
fi

config="$config_dir/$image.yaml"
if [[ ! -f "$config" ]]; then
  echo "structure-test: no config at $config - nothing to assert for '$image'"
  exit 0
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

runner="${LARAOCI_CST_CMD:-container-structure-test}"
if ! command -v "$runner" >/dev/null 2>&1; then
  echo "error: '$runner' not found. Install container-structure-test." >&2
  exit 1
fi

exec "$runner" test --image "$ref" "${configs[@]}"
