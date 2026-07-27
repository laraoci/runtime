# LARAOCI_MEASURE_CMD receives the ref as $1 and echoes a byte count.
# Branch on the image name embedded in the ref.
setup() {
  export CONFIG=tests/fixtures/budgets.yml
  # LARAOCI_MEASURE_CMD is a test-only seam and now says so (L6).
  export LARAOCI_TEST=1
}

@test "size-check: passes when every image is under budget" {
  export LARAOCI_MEASURE_CMD='echo 50000000'   # 50 MB, under all budgets
  run bin/size-check.sh
  [ "$status" -eq 0 ]
}

@test "size-check: fails non-zero when an image is over budget" {
  export LARAOCI_MEASURE_CMD='case "$1" in *runtime*) echo 900000000;; *) echo 10000000;; esac'
  run bin/size-check.sh
  [ "$status" -ne 0 ]
}

@test "size-check: reports the delta for an overrun" {
  export LARAOCI_MEASURE_CMD='case "$1" in *runtime*) echo 250000000;; *) echo 10000000;; esac'
  run bin/size-check.sh --image runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *"OVER"* ]]
  [[ "$output" == *"runtime"* ]]
}

@test "size-check: --report never fails even on overrun" {
  export LARAOCI_MEASURE_CMD='echo 900000000'   # over every budget
  run bin/size-check.sh --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"OVER"* ]]
}

@test "size-check: --image limits the check to one image" {
  export LARAOCI_MEASURE_CMD='echo 10000000'
  run bin/size-check.sh --image cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"cli"* ]]
  [[ "$output" != *"builder"* ]]
}

@test "size-check: an unknown --image is a hard error, not a silent pass (M1)" {
  export LARAOCI_MEASURE_CMD='echo 1'
  run bin/size-check.sh --image runtimee
  [ "$status" -eq 2 ]
  [[ "$output" == *"no size budget"* ]]
  [[ "$output" == *"runtimee"* ]]
}

@test "size-check: the report carries two decimal places (L1)" {
  export LARAOCI_MEASURE_CMD='echo 260900000'
  run bin/size-check.sh --image runtime --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"260.90"* ]]
}

@test "size-check: a marginal overrun shows a positive delta, not 0.00 (L1)" {
  # The fixture budget for runtime is 220 MB, so 220.40 MB is 0.40 over.
  export LARAOCI_MEASURE_CMD='echo 220400000'
  run bin/size-check.sh --image runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *"220.40"* ]]
  [[ "$output" == *"0.40"* ]]
  [[ "$output" == *"OVER"* ]]
}

@test "size-check: LARAOCI_MEASURE_CMD is inert without LARAOCI_TEST=1 (L6)" {
  unset LARAOCI_TEST
  export LARAOCI_MEASURE_CMD='echo 1'
  run bin/size-check.sh --image runtime
  [ "$status" -eq 2 ]
  [[ "$output" == *"LARAOCI_TEST"* ]]
}
