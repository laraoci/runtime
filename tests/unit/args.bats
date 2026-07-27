# Every usage error in this project exits 2 (see structure-test.bats). A missing
# option VALUE used to escape that convention and die on `$2: unbound variable`
# with exit 1 instead.

@test "args: affected.sh --base with no value exits 2" {
  run bin/affected.sh --base
  [ "$status" -eq 2 ]
  [[ "$output" == *"--base requires a value"* ]]
}

@test "args: matrix.sh --php with no value exits 2" {
  run bin/matrix.sh --php
  [ "$status" -eq 2 ]
  [[ "$output" == *"--php requires a value"* ]]
}

@test "args: matrix.sh --image with no value exits 2" {
  run bin/matrix.sh --image
  [ "$status" -eq 2 ]
  [[ "$output" == *"--image requires a value"* ]]
}

@test "args: matrix.sh --platform with no value exits 2" {
  run bin/matrix.sh --platform
  [ "$status" -eq 2 ]
  [[ "$output" == *"--platform requires a value"* ]]
}

@test "args: size-check.sh --image with no value exits 2" {
  run bin/size-check.sh --image
  [ "$status" -eq 2 ]
  [[ "$output" == *"--image requires a value"* ]]
}

@test "args: structure-test.sh --image with no value exits 2" {
  run bin/structure-test.sh --image
  [ "$status" -eq 2 ]
  [[ "$output" == *"--image requires a value"* ]]
}

@test "args: structure-test.sh --ref with no value exits 2" {
  run bin/structure-test.sh --image runtime --ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ref requires a value"* ]]
}

@test "args: structure-test.sh --config-dir with no value exits 2" {
  run bin/structure-test.sh --image runtime --ref x --config-dir
  [ "$status" -eq 2 ]
  [[ "$output" == *"--config-dir requires a value"* ]]
}

@test "args: an explicitly empty value is rejected too" {
  run bin/size-check.sh --image ""
  [ "$status" -eq 2 ]
}
