setup() {
  export LARAOCI_TEST=1
}

@test "build-chain: a root image builds only itself" {
  run bin/build-chain.sh --image runtime --php 8.4 --dry-run
  [ "$status" -eq 0 ]
  [ "$(grep -c '^build ' <<<"$output")" -eq 1 ]
  [[ "${lines[0]}" == "build runtime images/runtime/Dockerfile ghcr.io/laraoci/runtime:8.4-trixie" ]]
}

@test "build-chain: a child builds its ancestors first, in order" {
  run bin/build-chain.sh --image queue --php 8.4 --dry-run
  [ "$status" -eq 0 ]
  # The header lines only. Each one is followed by its indented --build-arg and
  # --label lines, so indexing $lines directly reads an argument, not the next
  # image - which is why the case below greps rather than indexes.
  mapfile -t headers < <(grep '^build ' <<<"$output")
  [ "${#headers[@]}" -eq 3 ]
  [[ "${headers[0]}" == build\ runtime\ * ]]
  [[ "${headers[1]}" == build\ cli\ * ]]
  [[ "${headers[2]}" == build\ queue\ * ]]
}

@test "build-chain: a child is built with PARENT_REF pointing at its parent" {
  run bin/build-chain.sh --image cli --php 8.3 --dry-run
  [[ "$output" == *"PARENT_REF=ghcr.io/laraoci/runtime:8.3-trixie"* ]]
}

# The root derives from the upstream php image, so PARENT_REF is meaningless to
# it. BASE_DIGEST is deliberately not passed either: images/runtime/Dockerfile
# documents an empty value as correct for a local build off the tag, and
# resolving the real digest would put a registry round-trip in front of every
# offline rebuild for the sake of one label. CI passes it on the leg that
# publishes the image.
@test "build-chain: the root gets neither PARENT_REF nor a BASE_DIGEST lookup" {
  run bin/build-chain.sh --image runtime --php 8.4 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"PARENT_REF"* ]]
  [[ "$output" != *"BASE_DIGEST"* ]]
}

@test "build-chain: the debian suite comes from config, not a literal" {
  # The fixture overrides ONLY 8.3 - §3.1's transition mechanism, one version
  # held on the older suite. 8.4 stays on defaults.debian, which is exactly what
  # tests/unit/matrix.bats asserts against the same fixture, so asking for 8.4
  # here would prove nothing about the override.
  CONFIG=tests/fixtures/debian-override.yml run bin/build-chain.sh --image runtime --php 8.3 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/laraoci/runtime:8.3-bookworm"* ]]
  [[ "$output" != *trixie* ]]
}

# .github/workflows/build.yml calls this on the load path and then builds the
# target itself, so building the target here too would be a wasted duplicate.
@test "build-chain: --ancestors-only stops short of the target" {
  run bin/build-chain.sh --image queue --php 8.4 --dry-run --ancestors-only
  [ "$status" -eq 0 ]
  mapfile -t headers < <(grep '^build ' <<<"$output" || true)
  [ "${#headers[@]}" -eq 2 ]
  [[ "${headers[0]}" == build\ runtime\ * ]]
  [[ "${headers[1]}" == build\ cli\ * ]]
  [[ "$output" != *"build queue "* ]]
}

# The workflow calls it unconditionally, so the root must be a silent success
# rather than something the caller has to guard against.
@test "build-chain: --ancestors-only on the graph root builds nothing" {
  run bin/build-chain.sh --image runtime --php 8.4 --dry-run --ancestors-only
  [ "$status" -eq 0 ]
  mapfile -t headers < <(grep '^build ' <<<"$output" || true)
  [ "${#headers[@]}" -eq 0 ]
}

@test "build-chain: an unknown image exits 2" {
  run bin/build-chain.sh --image nope --php 8.4 --dry-run
  [ "$status" -eq 2 ]
}

@test "build-chain: --image without a value exits 2" {
  run bin/build-chain.sh --image
  [ "$status" -eq 2 ]
}
