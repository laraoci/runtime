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
