# bin/assert-metadata.sh is the ONLY place STOPSIGNAL is asserted anywhere in
# this repository - container-structure-test's metadataTest schema has no field
# for it and a container cannot read its own. It is also the only §11 label
# check, because the labels are applied by the workflow rather than by the
# Dockerfile. Both assertions must hold identically on the load path and on the
# push path, which is why there is one script with two sources rather than two
# copies of the same shell in build.yml.

setup() {
  PATH="$PWD/bin:$PATH"
  export LARAOCI_TEST=1
}

# A complete, passing OCI image config as `docker buildx imagetools inspect
# --format '{{ json .Image }}'` returns it for a SINGLE-platform manifest.
single_config() {
  cat <<'JSON'
{
  "created": "2026-08-01T00:00:00Z",
  "architecture": "arm64",
  "os": "linux",
  "config": {
    "Env": ["PATH=/usr/local/bin"],
    "Cmd": ["php-fpm"],
    "StopSignal": "SIGQUIT",
    "Labels": {
      "org.opencontainers.image.title": "laraoci/fpm",
      "org.opencontainers.image.description": "PHP-FPM for Laravel",
      "org.opencontainers.image.source": "https://github.com/laraoci/runtime",
      "org.opencontainers.image.documentation": "https://github.com/laraoci/runtime#readme",
      "org.opencontainers.image.revision": "deadbeef",
      "org.opencontainers.image.created": "2026-08-01T00:00:00Z",
      "org.opencontainers.image.version": "8.4-trixie",
      "org.opencontainers.image.licenses": "MIT",
      "org.opencontainers.image.base.name": "ghcr.io/laraoci/runtime",
      "org.opencontainers.image.base.digest": "sha256:abc"
    }
  }
}
JSON
}

# The same, as a manifest LIST: a map keyed by platform, plus the
# unknown/unknown entry BuildKit adds for the SBOM and provenance manifests.
index_config() {
  jq -n --argjson c "$(single_config)" '{
    "linux/amd64": ($c | .architecture = "amd64"),
    "linux/arm64": $c,
    "unknown/unknown": {"created": null}
  }'
}

@test "assert-metadata: passes on a complete single-platform registry config" {
  export LARAOCI_INSPECT_CMD="$(declare -f single_config); single_config"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm@sha256:aaa --source registry
  [ "$status" -eq 0 ]
}

@test "assert-metadata: passes on a manifest list and checks EVERY platform" {
  export LARAOCI_INSPECT_CMD="$(declare -f single_config; declare -f index_config); index_config"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm:8.4-trixie --source registry
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux/amd64"* ]]
  [[ "$output" == *"linux/arm64"* ]]
}

@test "assert-metadata: skips the unknown/unknown attestation entries" {
  # BuildKit attaches the SBOM and provenance as manifests with platform
  # unknown/unknown. They carry no image config; treating them as a platform
  # would fail every signed image for missing labels it was never meant to have.
  export LARAOCI_INSPECT_CMD="$(declare -f single_config; declare -f index_config); index_config"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm:8.4-trixie --source registry
  [ "$status" -eq 0 ]
  [[ "$output" != *"unknown/unknown"* ]]
}

@test "assert-metadata: a missing label fails, and names the label" {
  export LARAOCI_INSPECT_CMD="$(declare -f single_config); single_config | jq 'del(.config.Labels.\"org.opencontainers.image.revision\")'"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm@sha256:aaa --source registry
  [ "$status" -eq 1 ]
  [[ "$output" == *"org.opencontainers.image.revision"* ]]
}

@test "assert-metadata: an empty label fails - present is not the assertion" {
  export LARAOCI_INSPECT_CMD="$(declare -f single_config); single_config | jq '.config.Labels.\"org.opencontainers.image.base.digest\" = \"\"'"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm@sha256:aaa --source registry
  [ "$status" -eq 1 ]
  [[ "$output" == *"base.digest"* ]]
}

@test "assert-metadata: fpm without SIGQUIT fails - the truncated-response bug" {
  # §6.2 / M2 trap 1. php-fpm reads SIGQUIT as a graceful drain and SIGTERM as
  # immediate death, so an fpm image left on the parent's SIGTERM truncates an
  # in-flight response on every deploy. Nothing else in this repository catches
  # it - which is why it is skipped on exactly the builds that ship, until now.
  export LARAOCI_INSPECT_CMD="$(declare -f single_config); single_config | jq '.config.StopSignal = \"SIGTERM\"'"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm@sha256:aaa --source registry
  [ "$status" -eq 1 ]
  [[ "$output" == *"SIGQUIT"* ]]
}

@test "assert-metadata: a runtime that lost its STOPSIGNAL line fails" {
  # Absent means SIGTERM only because runtime sets SIGTERM explicitly and every
  # descendant inherits it. An image that never set one reports the empty
  # string, so the empty string must not silently satisfy 'SIGTERM'.
  export LARAOCI_INSPECT_CMD="$(declare -f single_config); single_config | jq 'del(.config.StopSignal)'"
  run assert-metadata.sh --image runtime --ref ghcr.io/laraoci/runtime@sha256:aaa --source registry
  [ "$status" -eq 1 ]
  [[ "$output" == *"SIGTERM"* ]]
}

@test "assert-metadata: the daemon source reads docker image inspect's shape" {
  # docker image inspect --format '{{json .Config}}' returns the Config object
  # itself, not the whole image config - one level shallower than imagetools.
  export LARAOCI_INSPECT_CMD="$(declare -f single_config); single_config | jq '.config'"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm:8.4-trixie --source daemon
  [ "$status" -eq 0 ]
}

@test "assert-metadata: the test seam refuses to run outside a test" {
  # Same guard as bin/size-check.sh's LARAOCI_MEASURE_CMD (L6): a seam that
  # bypasses the registry read must not be reachable from production code.
  unset LARAOCI_TEST
  export LARAOCI_INSPECT_CMD="echo '{}'"
  run assert-metadata.sh --image fpm --ref ghcr.io/laraoci/fpm@sha256:aaa --source registry
  [ "$status" -eq 2 ]
  [[ "$output" == *"test-only seam"* ]]
}

@test "assert-metadata: an unknown --source is a usage error" {
  run assert-metadata.sh --image fpm --ref x --source magic
  [ "$status" -eq 2 ]
}

@test "assert-metadata: --image and --ref are required" {
  run assert-metadata.sh --ref x
  [ "$status" -eq 2 ]
  run assert-metadata.sh --image fpm
  [ "$status" -eq 2 ]
}
