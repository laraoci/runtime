setup() {
  PATH="$PWD/bin:$PATH"
  export LARAOCI_TEST=1
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/structure" "$TMP/bin"
  cat >"$TMP/bin/fake-cst" <<'FAKE'
#!/usr/bin/env bash
echo "cst called: $*"
FAKE
  chmod +x "$TMP/bin/fake-cst"
  export LARAOCI_CST_CMD="$TMP/bin/fake-cst"
}

teardown() {
  rm -rf "$TMP"
}

@test "structure-test: no config for the image is a no-op, not a failure" {
  run bin/structure-test.sh --image cli --ref ghcr.io/laraoci/cli:8.4-trixie --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no config"* ]]
}

@test "structure-test: runs the checker when a config exists" {
  touch "$TMP/structure/runtime.yaml"
  run bin/structure-test.sh --image runtime --ref ghcr.io/laraoci/runtime:8.4-trixie --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cst called: test --image ghcr.io/laraoci/runtime:8.4-trixie --config $TMP/structure/runtime.yaml"* ]]
}

# The shared contract and the image's own file are BOTH passed, shared first.
# The whole command line is asserted rather than two substrings, so that the
# order - and the absence of anything else - is pinned too.
@test "structure-test: the shared contract runs alongside the image's own config" {
  touch "$TMP/structure/_common.yaml" "$TMP/structure/cli.yaml"
  run bin/structure-test.sh --image cli --ref ghcr.io/laraoci/cli:8.4-trixie --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cst called: test --image ghcr.io/laraoci/cli:8.4-trixie --config $TMP/structure/_common.yaml --config $TMP/structure/cli.yaml"* ]]
}

# Pins the deliberate half of that rule: the shared file does not drag an image
# with no config of its own into being tested. "Gain coverage by adding a file"
# stays true, and a variant that legitimately cannot satisfy the common contract
# opts out by not having a file rather than by a skip flag.
@test "structure-test: the shared contract alone does not make an unconfigured image run" {
  touch "$TMP/structure/_common.yaml"
  run bin/structure-test.sh --image queue --ref ghcr.io/laraoci/queue:8.4-trixie --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no config"* ]]
  [[ "$output" != *"cst called"* ]]
}

@test "structure-test: --image is required" {
  run bin/structure-test.sh --ref ghcr.io/laraoci/runtime:8.4-trixie
  [ "$status" -eq 2 ]
}

# --- deriving the ref (the local path) --------------------------------------
# CI always passes --ref, because only CI knows what it just built. Locally
# there is nothing to pass, so an omitted --ref is composed from the same config
# bin/build-chain.sh tags with. These pin that the two cannot drift apart.

@test "structure-test: an omitted --ref is derived from the config's default version" {
  touch "$TMP/structure/runtime.yaml"
  CONFIG=tests/fixtures/debian-override.yml run bin/structure-test.sh \
    --image runtime --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  # 8.4 carries `default: true` in that fixture, and takes defaults.debian.
  [[ "$output" == *"cst called: test --image ghcr.io/laraoci/runtime:8.4-trixie"* ]]
}

@test "structure-test: a derived ref honours a per-version debian override" {
  # The §3.1 transition mechanism. Deriving from defaults.debian alone would
  # produce a tag that was never built, and the failure would look like a
  # missing image rather than a wrong suite.
  touch "$TMP/structure/runtime.yaml"
  CONFIG=tests/fixtures/debian-override.yml run bin/structure-test.sh \
    --image runtime --php 8.3 --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cst called: test --image ghcr.io/laraoci/runtime:8.3-bookworm"* ]]
}

@test "structure-test: an explicit --ref still wins over derivation" {
  # CI's path. A digest-pinned release ref cannot be derived from anything here,
  # so --ref must never be second-guessed.
  touch "$TMP/structure/runtime.yaml"
  CONFIG=tests/fixtures/debian-override.yml run bin/structure-test.sh \
    --image runtime --ref example.test/other:tag --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cst called: test --image example.test/other:tag"* ]]
}

@test "structure-test: an unsupported --php is rejected, not turned into a tag" {
  touch "$TMP/structure/runtime.yaml"
  CONFIG=tests/fixtures/debian-override.yml run bin/structure-test.sh \
    --image runtime --php 9.9 --config-dir "$TMP/structure"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a supported PHP version"* ]]
}

@test "structure-test: an image with no config needs no config file at all" {
  # The no-op must stay reachable without yq, a readable images.yml or a valid
  # version - which is why the ref is derived AFTER the config-file check and
  # not during argument parsing.
  CONFIG=/nonexistent/images.yml run bin/structure-test.sh \
    --image queue --config-dir "$TMP/structure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no config"* ]]
}

@test "structure-test: an unknown argument fails loudly" {
  run bin/structure-test.sh --image runtime --ref x --nope
  [ "$status" -eq 2 ]
}

@test "structure-test: the seam refuses to run outside a test" {
  # LARAOCI_CST_CMD replaces the entire checker, so `LARAOCI_CST_CMD=true` makes
  # all 35 structure assertions pass on both the PR and the push path. It is the
  # strongest of the four seams and was the only one without the L6 guard.
  unset LARAOCI_TEST
  run bash -c "LARAOCI_CST_CMD=true structure-test.sh --image runtime"
  [ "$status" -eq 2 ]
  [[ "$output" == *"test-only seam"* ]]
}
