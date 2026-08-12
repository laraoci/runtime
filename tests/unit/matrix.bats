setup() {
  PATH="$PWD/bin:$PATH"
}

@test "matrix: full matrix emits exactly 36 legs" {
  run bash -c "bin/matrix.sh | jq '.include | length'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 36 ]
}

@test "matrix: output is a valid object with an include array" {
  run bash -c "bin/matrix.sh | jq -e '.include | type == \"array\"'"
  [ "$status" -eq 0 ]
}

@test "matrix: every leg has php, image, platform" {
  run bash -c "bin/matrix.sh | jq -e '.include | all(has(\"php\") and has(\"image\") and has(\"platform\"))'"
  [ "$status" -eq 0 ]
}

@test "matrix: runtime is ordered before its children (topological)" {
  first_runtime=$(bin/matrix.sh | jq -r '[.include[].image] | index("runtime")')
  first_cli=$(bin/matrix.sh | jq -r '[.include[].image] | index("cli")')
  first_queue=$(bin/matrix.sh | jq -r '[.include[].image] | index("queue")')
  [ "$first_runtime" -lt "$first_cli" ]
  [ "$first_cli" -lt "$first_queue" ]
}

@test "matrix: deprecated php versions are skipped" {
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/matrix.sh | jq '.include | length'"
  [ "$output" -eq 24 ]
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/matrix.sh | jq -e '[.include[].php] | index(\"8.5\") == null'"
  [ "$status" -eq 0 ]
}

@test "matrix: per-image platform override is honoured" {
  run bash -c "CONFIG=tests/fixtures/platform-override.yml bin/matrix.sh | jq '.include | length'"
  [ "$output" -eq 33 ]
  run bash -c "CONFIG=tests/fixtures/platform-override.yml bin/matrix.sh | jq -e '[.include[] | select(.image==\"builder\") | .platform] | unique == [\"linux/amd64\"]'"
  [ "$status" -eq 0 ]
}

@test "matrix: --php filter narrows to one version" {
  run bash -c "bin/matrix.sh --php 8.4 | jq -e '[.include[].php] | unique == [\"8.4\"]'"
  [ "$status" -eq 0 ]
  run bash -c "bin/matrix.sh --php 8.4 | jq '.include | length'"
  [ "$output" -eq 12 ]
}

@test "matrix: --image and --platform filters compose" {
  run bash -c "bin/matrix.sh --image runtime --platform linux/amd64 | jq '.include | length'"
  [ "$output" -eq 3 ]
}

@test "matrix: every leg carries the dockerfile path from config" {
  run bash -c "bin/matrix.sh | jq -e '.include | all(has(\"dockerfile\") and (.dockerfile | length > 0))'"
  [ "$status" -eq 0 ]
}

@test "matrix: the runtime leg points at images/runtime/Dockerfile" {
  run bash -c "bin/matrix.sh --image runtime --php 8.4 --platform linux/amd64 | jq -r '.include[0].dockerfile'"
  [ "$output" = "images/runtime/Dockerfile" ]
}

@test "matrix: every leg carries the debian suite from config (M2)" {
  run bash -c "bin/matrix.sh | jq -e '.include | all(.debian == \"trixie\")'"
  [ "$status" -eq 0 ]
}

@test "matrix: a per-version debian override is honoured (spec §271)" {
  run bash -c "CONFIG=tests/fixtures/debian-override.yml bin/matrix.sh | jq -r '[.include[] | select(.php == \"8.3\") | .debian] | unique | .[]'"
  [ "$output" = "bookworm" ]
}

@test "matrix: a version without an override falls back to defaults.debian" {
  run bash -c "CONFIG=tests/fixtures/debian-override.yml bin/matrix.sh | jq -r '[.include[] | select(.php == \"8.4\") | .debian] | unique | .[]'"
  [ "$output" = "trixie" ]
}

@test "matrix: every leg carries a runner, a parent key and a depth (LOCI-040)" {
  run bash -c "bin/matrix.sh | jq -e '.include | all(has(\"runner\") and has(\"parent\") and has(\"depth\"))'"
  [ "$status" -eq 0 ]
}

@test "matrix: the runner is the native one for the platform (D3a, no QEMU)" {
  run bash -c "bin/matrix.sh --image runtime --php 8.4 --platform linux/amd64 | jq -r '.include[0].runner'"
  [ "$output" = "ubuntu-24.04" ]
  run bash -c "bin/matrix.sh --image runtime --php 8.4 --platform linux/arm64 | jq -r '.include[0].runner'"
  [ "$output" = "ubuntu-24.04-arm" ]
}

@test "matrix: no leg runs arm64 on an amd64 runner (the QEMU regression)" {
  # The whole point of D3a. A cross pairing here means an arm64 image was built
  # under emulation, which is the cost the decision exists to avoid - and it
  # would still produce a green, publishable, wrong-by-construction artifact.
  run bash -c "bin/matrix.sh | jq -e '.include | all(
    (.platform == \"linux/arm64\") == (.runner | endswith(\"-arm\")))'"
  [ "$status" -eq 0 ]
}

@test "matrix: a platform with no runner mapping is a hard error, not a default" {
  # Defaulting to ubuntu-latest is how an arm64 leg silently becomes an emulated
  # amd64 one, published under a name that claims otherwise.
  run bash -c "CONFIG=tests/fixtures/runners.yml bin/matrix.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no runner for platform"* ]]
}

@test "matrix: depth is the distance from the graph root" {
  run bash -c "bin/matrix.sh --image runtime --php 8.4 --platform linux/amd64 | jq -r '.include[0].depth'"
  [ "$output" = "0" ]
  run bash -c "bin/matrix.sh --image cli --php 8.4 --platform linux/amd64 | jq -r '.include[0].depth'"
  [ "$output" = "1" ]
  run bash -c "bin/matrix.sh --image queue --php 8.4 --platform linux/amd64 | jq -r '.include[0].depth'"
  [ "$output" = "2" ]
}

@test "matrix: parent is the config's parent, empty for the root" {
  run bash -c "bin/matrix.sh --image runtime --php 8.4 --platform linux/amd64 | jq -r '.include[0].parent'"
  [ "$output" = "" ]
  run bash -c "bin/matrix.sh --image queue --php 8.4 --platform linux/amd64 | jq -r '.include[0].parent'"
  [ "$output" = "cli" ]
}

@test "matrix: --depth slices the matrix for the staged release path" {
  # 6 legs at depth 0 (runtime x 3 php x 2 platforms), 18 at depth 1
  # (cli, fpm, builder), 12 at depth 2 (queue, scheduler) - 36 in total.
  run bash -c "bin/matrix.sh --depth 0 | jq '.include | length'"
  [ "$output" -eq 6 ]
  run bash -c "bin/matrix.sh --depth 1 | jq '.include | length'"
  [ "$output" -eq 18 ]
  run bash -c "bin/matrix.sh --depth 2 | jq '.include | length'"
  [ "$output" -eq 12 ]
  run bash -c "bin/matrix.sh --depth 1 | jq -e '[.include[].image] | unique == [\"builder\",\"cli\",\"fpm\"]'"
  [ "$status" -eq 0 ]
}

@test "matrix: one merge job per image x php is derivable from a single platform" {
  # release.yml builds its merge matrices this way rather than inventing a
  # second selector: one platform slice of a depth IS the image x php set.
  run bash -c "bin/matrix.sh --depth 1 --platform linux/amd64 | jq '.include | length'"
  [ "$output" -eq 9 ]
}

@test "matrix: --include-deprecated puts a deprecated version back in the matrix" {
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/matrix.sh --include-deprecated | jq '.include | length'"
  [ "$output" -eq 36 ]
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/matrix.sh --include-deprecated | jq -e '[.include[].php] | index(\"8.5\") != null'"
  [ "$status" -eq 0 ]
}
