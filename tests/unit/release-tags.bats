setup() {
  PATH="$PWD/bin:$PATH"
  export LARAOCI_TEST=1
}

@test "release-tags: the two rolling forms, from config not from literals" {
  run bash -c "release-tags.sh --image fpm --php 8.3 --kind rolling"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/laraoci/fpm:8.3"* ]]
  [[ "$output" == *"ghcr.io/laraoci/fpm:8.3-trixie"* ]]
}

@test "release-tags: :latest is emitted ONLY for the default PHP version (§8)" {
  # 8.4 carries default: true. Emitting :latest for 8.3 or 8.5 would point the
  # tag most consumers pull at a version the project did not choose for them.
  run bash -c "release-tags.sh --image fpm --php 8.4 --kind rolling"
  [[ "$output" == *"ghcr.io/laraoci/fpm:latest"* ]]
  run bash -c "release-tags.sh --image fpm --php 8.3 --kind rolling"
  [[ "$output" != *":latest"* ]]
  run bash -c "release-tags.sh --image fpm --php 8.5 --kind rolling"
  [[ "$output" != *":latest"* ]]
}

@test "release-tags: the dated form is immutable and carries the release suffix" {
  run bash -c "release-tags.sh --image cli --php 8.4 --kind immutable --dated-suffix -20260801"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/laraoci/cli:8.4-trixie-20260801"* ]]
}

@test "release-tags: --patch adds the patch+dated form (§8), and only then" {
  run bash -c "release-tags.sh --image cli --php 8.4 --kind immutable --dated-suffix -20260801"
  [[ "$output" != *"8.4.10"* ]]
  run bash -c "release-tags.sh --image cli --php 8.4 --kind immutable --dated-suffix -20260801 --patch 8.4.10"
  [[ "$output" == *"ghcr.io/laraoci/cli:8.4.10-trixie-20260801"* ]]
}

@test "release-tags: a same-day rebuild's -2 suffix flows through unchanged" {
  run bash -c "release-tags.sh --image cli --php 8.4 --kind immutable --dated-suffix -20260801-2"
  [[ "$output" == *"ghcr.io/laraoci/cli:8.4-trixie-20260801-2"* ]]
}

@test "release-tags: immutable without a suffix is a usage error, not a guess" {
  # Emitting `8.4-trixie-` or silently reading the clock here is how a release
  # ends up with two dates. The date has ONE source (🧭 2).
  run bash -c "release-tags.sh --image cli --php 8.4 --kind immutable"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--dated-suffix"* ]]
}

@test "release-tags: --kind all emits both sets" {
  run bash -c "release-tags.sh --image runtime --php 8.4 --kind all --dated-suffix -20260801"
  [[ "$output" == *"ghcr.io/laraoci/runtime:latest"* ]]
  [[ "$output" == *"ghcr.io/laraoci/runtime:8.4-trixie-20260801"* ]]
}

@test "release-tags: a per-version debian override reaches the tag (§3.1)" {
  run bash -c "CONFIG=tests/fixtures/debian-override.yml release-tags.sh --image runtime --php 8.3 --kind rolling"
  [[ "$output" == *":8.3-bookworm"* ]]
}

@test "release-tags: LARAOCI_REGISTRY redirects every form to the dry-run namespace" {
  run bash -c "LARAOCI_REGISTRY=ghcr.io/example/staging release-tags.sh --image fpm --php 8.4 --kind rolling"
  [[ "$output" == *"ghcr.io/example/staging/fpm:latest"* ]]
  [[ "$output" != *"laraoci"* ]]
}

@test "release-tags: an unsupported php version is rejected" {
  run bash -c "release-tags.sh --image fpm --php 9.9 --kind rolling"
  [ "$status" -eq 2 ]
}
