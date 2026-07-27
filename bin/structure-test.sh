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

runner="${LARAOCI_CST_CMD:-container-structure-test}"
if ! command -v "$runner" >/dev/null 2>&1; then
  echo "error: '$runner' not found. Install container-structure-test." >&2
  exit 1
fi

exec "$runner" test --image "$ref" --config "$config"
