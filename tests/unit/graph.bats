# matrix.sh and affected.sh read the same graph from the same file. They must
# never disagree about whether that file is well formed, so validation lives in
# common.sh and both are asserted against every malformed fixture.

@test "graph: matrix.sh rejects a cycle" {
  run bash -c "CONFIG=tests/fixtures/cycle.yml bin/matrix.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "graph: affected.sh rejects a cycle (L7)" {
  run bash -c "printf 'config/images.yml\n' | CONFIG=tests/fixtures/cycle.yml bin/affected.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "graph: matrix.sh rejects a dangling parent" {
  run bash -c "CONFIG=tests/fixtures/dangling.yml bin/matrix.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonexistent"* ]]
}

@test "graph: affected.sh rejects a dangling parent (L7)" {
  run bash -c "printf 'images/runtime/Dockerfile\n' | CONFIG=tests/fixtures/dangling.yml bin/affected.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nonexistent"* ]]
}

@test "graph: an image name with shell metacharacters is rejected (H1)" {
  run bash -c "CONFIG=tests/fixtures/bad-name.yml bin/matrix.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid image name"* ]]
}

@test "graph: affected.sh rejects an unsafe image name too (H1)" {
  run bash -c "printf 'config/images.yml\n' | CONFIG=tests/fixtures/bad-name.yml bin/affected.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid image name"* ]]
}

@test "graph: the real config is well formed" {
  run bash -c "bin/matrix.sh >/dev/null"
  [ "$status" -eq 0 ]
}

@test "graph: a multi-line dockerfile value is rejected, not silently absorbed" {
  # common.sh reads FOUR fields with four reads, one per line - which is correct,
  # and documented at length against the @tsv alternative. The hole is on the
  # VALUE side: yq -r emits a multi-line scalar as several lines, which desyncs
  # the read and shifts every subsequent value. The failure is silent graph
  # corruption, which is why it is worth a shape check on a repo-owned file.
  run bash -c "CONFIG=tests/fixtures/multiline-dockerfile.yml bin/matrix.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dockerfile"* ]]
}

@test "graph: affected.sh rejects a multi-line dockerfile value too (L7)" {
  # Both readers or neither: matrix.sh and affected.sh must never disagree about
  # whether config/images.yml is well-formed.
  run bash -c "printf 'config/images.yml\n' | CONFIG=tests/fixtures/multiline-dockerfile.yml bin/affected.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dockerfile"* ]]
}
