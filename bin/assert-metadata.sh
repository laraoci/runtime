#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# THE TWO IMAGE-CONFIG ASSERTIONS container-structure-test cannot make:
#
#   - the §11 OCI label set, because the labels are applied by
#     .github/workflows/build.yml rather than by the Dockerfile; and
#   - STOPSIGNAL, because CST's metadataTest schema has no field for it and a
#     container cannot read its own.
#
# The second is the load-bearing one. images/fpm restores SIGQUIT because
# php-fpm reads it as "drain, then exit" where SIGTERM means "die now" (§6.2,
# M2 trap 1); an fpm image that lost it truncates an in-flight response on
# every single deploy, invisibly, under load. This script is the ONLY place
# that is checked.
#
# It exists as a script rather than as inline workflow shell for one reason:
# docs/release-verification.md requires the assertion to run on the PUSH path,
# against the pushed digest, and two copies of this logic in one workflow file
# would drift. One script, two sources:
#
#   --source daemon    docker image inspect --format '{{json .Config}}'
#                      the load path: one platform, already in the daemon.
#
#   --source registry  docker buildx imagetools inspect --format '{{json .Image}}'
#                      the push path: reads the config blob straight from the
#                      registry, so the PUBLISHED bytes are what is asserted and
#                      NOTHING is pulled. For a manifest list the result is a map
#                      keyed by platform, so both architectures are covered by
#                      one call.
#
# docs/release-verification.md says the stop signal needs a pull-then-
# `docker image inspect`. It does not - the manifest carries the config blob and
# imagetools will render it. The doc is corrected alongside this script.

usage() {
  echo "usage: assert-metadata.sh --image NAME --ref REF [--source daemon|registry] [--platform P]..." >&2
}

image=""
ref=""
source_kind="daemon"
platforms=()

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
    --source)
      require_arg "$1" "${2:-}"
      source_kind="$2"
      shift 2
      ;;
    --platform)
      require_arg "$1" "${2:-}"
      platforms+=("$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$image" || -z "$ref" ]]; then
  echo "error: --image and --ref are required" >&2
  usage
  exit 2
fi

case "$source_kind" in
  daemon | registry) : ;;
  *)
    echo "error: --source must be 'daemon' or 'registry', got '$source_kind'" >&2
    exit 2
    ;;
esac

# Same guard bin/size-check.sh applies to LARAOCI_MEASURE_CMD (L6). A seam that
# replaces the registry read must never be reachable from production code - it
# would turn this assertion into whatever the caller felt like printing.
if [[ -n "${LARAOCI_INSPECT_CMD:-}" && "${LARAOCI_TEST:-0}" != "1" ]]; then
  echo "error: LARAOCI_INSPECT_CMD is a test-only seam; set LARAOCI_TEST=1 to use it." >&2
  exit 2
fi

require_mikefarah_yq

inspect() {
  if [[ -n "${LARAOCI_INSPECT_CMD:-}" ]]; then
    bash -c "$LARAOCI_INSPECT_CMD" _ "$ref"
  elif [[ "$source_kind" == "registry" ]]; then
    docker buildx imagetools inspect "$ref" --format '{{ json .Image }}'
  else
    docker image inspect "$ref" --format '{{json .Config}}'
  fi
}

raw="$(inspect)"

# Normalise all three shapes to one map of platform -> {config: {...}}:
#
#   daemon                   {Labels, StopSignal, ...}          (the Config itself)
#   registry, one platform   {created, architecture, config}    (the image config)
#   registry, manifest list  {"linux/amd64": {...image config}} (a map)
#
# `unknown/unknown` entries are dropped: BuildKit attaches the SBOM and the
# provenance as manifests carrying that platform, they have no image config, and
# treating one as a platform would fail every signed image for labels it was
# never supposed to have.
configs="$(jq -c --arg ref "$ref" '
  if has("Labels") or has("StopSignal") or has("Cmd") or has("Env") then
    {($ref): {config: .}}
  elif has("config") then
    # Keyed by the platform the config DECLARES, not by the ref. Every release
    # leg pushes one platform by digest and then asserts that digest carries the
    # platform it was told to build - so a lone config keyed by its reference
    # could never satisfy --platform, and the push path failed with "carries no
    # linux/amd64 manifest" against an image that was linux/amd64.
    #
    # No variant in the key: the matrix speaks in `linux/arm64`, while a config
    # may also carry variant v8, and `linux/arm64/v8` would miss just as badly.
    {("\(.os)/\(.architecture)"): .}
  else
    with_entries(select(.key | test("^unknown/") | not))
  end' <<<"$raw")"

if [[ "$(jq -r 'length' <<<"$configs")" == "0" ]]; then
  echo "::error::no image config found for ${ref} - nothing was asserted" >&2
  exit 1
fi

# If the caller named platforms, every one of them must be present. A leg that
# expected two architectures and silently asserted one is the multi-arch digest
# degrading to single-arch (finding 12), read from the other end.
for want in "${platforms[@]+"${platforms[@]}"}"; do
  if [[ "$(WANT="$want" jq -r 'has(env.WANT)' <<<"$configs")" != "true" ]]; then
    echo "::error::${ref} carries no ${want} manifest" >&2
    jq -r 'keys[]' <<<"$configs" >&2
    exit 1
  fi
done

# The expectation comes from config/images.yml, not from a literal here, so an
# image that changes its mind changes one file. Absent means SIGTERM - which is
# real inheritance, not a default: every image inherits runtime's explicit
# SIGTERM, so an image that never set one anywhere reports the empty string and
# must NOT satisfy this.
want_signal="$(IMAGE="$image" "$YQ" -r '.images[strenv(IMAGE)].stopsignal // "SIGTERM"' "$CONFIG")"

required_labels=(
  source revision created version licenses
  description documentation base.name base.digest
)

fail=0
while IFS= read -r platform; do
  [[ -z "$platform" ]] && continue
  cfg="$(P="$platform" jq -c '.[env.P]' <<<"$configs")"
  labels="$(jq -c '.config.Labels // {}' <<<"$cfg")"

  for key in "${required_labels[@]}"; do
    if ! jq -e --arg k "org.opencontainers.image.$key" \
      '.[$k] // "" | length > 0' >/dev/null <<<"$labels"; then
      echo "::error::${platform}: missing or empty label org.opencontainers.image.${key}" >&2
      fail=1
    fi
  done

  got_signal="$(jq -r '.config.StopSignal // ""' <<<"$cfg")"
  if [[ "$got_signal" != "$want_signal" ]]; then
    echo "::error::${platform}: ${image} should carry STOPSIGNAL ${want_signal} (config/images.yml) but reports '${got_signal}'" >&2
    fail=1
  else
    echo "${platform}: stop signal ${got_signal}"
  fi

  jq . <<<"$labels"
done < <(jq -r 'keys[]' <<<"$configs")

exit "$fail"
