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

# --- which tag gets measured -------------------------------------------------
# This used to default to the literal `local`, which nothing in this repository
# ever tags, so every run without LARAOCI_TAG measured an image that could not
# exist. The ref is asserted directly - the seam receives it as $1 - because a
# wrong tag is invisible in the output table.

@test "size-check: an unset LARAOCI_TAG measures the config's default version" {
  export LARAOCI_MEASURE_CMD='echo "ref=$1" >&2; echo 1000000'
  run bin/size-check.sh --image runtime --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=ghcr.io/laraoci/runtime:8.4-trixie"* ]]
  [[ "$output" != *":local"* ]]
}

@test "size-check: --php selects the tag to measure" {
  export LARAOCI_MEASURE_CMD='echo "ref=$1" >&2; echo 1000000'
  run bin/size-check.sh --image runtime --php 8.3 --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=ghcr.io/laraoci/runtime:8.3-trixie"* ]]
}

@test "size-check: LARAOCI_TAG still wins over derivation" {
  # CI's path: it sets the tag for the leg it just built, and that must never be
  # second-guessed from the config.
  export LARAOCI_TAG=9.9-forced
  export LARAOCI_MEASURE_CMD='echo "ref=$1" >&2; echo 1000000'
  run bin/size-check.sh --image runtime --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=ghcr.io/laraoci/runtime:9.9-forced"* ]]
}

@test "size-check: an unknown --image errors before any tag is resolved" {
  # The image filter is validated FIRST. With the order reversed, a typo in
  # --image reported a tag-derivation failure instead of the real mistake.
  export LARAOCI_MEASURE_CMD='echo 1'
  CONFIG=tests/fixtures/dangling.yml run bin/size-check.sh --image nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"no size budget"* ]]
}

@test "size-check: --ref measures exactly that reference (D17 on the push path)" {
  # The release path measures the PUSHED DIGEST, which cannot be derived from
  # config: it is whatever BuildKit produced. The seam echoes the ref it was
  # handed so the test can prove the derivation was bypassed.
  run bash -c "LARAOCI_TEST=1 LARAOCI_MEASURE_CMD='echo \$1 >&2; echo 1000000' \
    bin/size-check.sh --image runtime --ref ghcr.io/laraoci/runtime@sha256:abc"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/laraoci/runtime@sha256:abc"* ]]
}

@test "size-check: --ref without --image is a usage error" {
  # A digest identifies one image, so a ref with no image name has no budget to
  # be measured against - and silently measuring all six against one ref would
  # report five wrong rows.
  run bash -c "bin/size-check.sh --ref ghcr.io/laraoci/runtime@sha256:abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--image"* ]]
}

@test "size-check: --ref is enforcing without --report (§9.2)" {
  # 400 MB against runtime's 260 MB budget. The release path drops --report so
  # an overrun exits 1 instead of printing a row nobody reads.
  run bash -c "LARAOCI_TEST=1 LARAOCI_MEASURE_CMD='echo 400000000' \
    bin/size-check.sh --image runtime --ref ghcr.io/laraoci/runtime@sha256:abc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OVER"* ]]
}

@test "size-check: --ref with --report stays advisory" {
  run bash -c "LARAOCI_TEST=1 LARAOCI_MEASURE_CMD='echo 400000000' \
    bin/size-check.sh --report --image runtime --ref ghcr.io/laraoci/runtime@sha256:abc"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OVER"* ]]
}

@test "size-check: --ref still validates the image against the budget set" {
  run bash -c "LARAOCI_TEST=1 LARAOCI_MEASURE_CMD='echo 1000000' \
    bin/size-check.sh --image nosuchimage --ref ghcr.io/laraoci/x@sha256:abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no size budget"* ]]
}
