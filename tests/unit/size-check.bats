# LARAOCI_MEASURE_CMD receives the ref as $1 and echoes a byte count.
# Branch on the image name embedded in the ref.
setup() {
  export CONFIG=tests/fixtures/budgets.yml
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
