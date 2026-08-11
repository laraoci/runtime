setup() {
  PATH="$PWD/bin:$PATH"
  export LARAOCI_TEST=1
}

@test "next-dated-suffix: an unused date yields the bare suffix" {
  run bash -c "LARAOCI_TAG_EXISTS_CMD='exit 1' next-dated-suffix.sh --date 20260801"
  [ "$status" -eq 0 ]
  [ "$output" = "-20260801" ]
}

@test "next-dated-suffix: a used date appends -2 (§8, never overwrite)" {
  # Dated tags are immutable. A same-day rebuild that reused the tag would
  # rewrite history for every consumer who pinned it.
  run bash -c "LARAOCI_TAG_EXISTS_CMD='case \$1 in *-20260801) exit 0;; *) exit 1;; esac' \
    next-dated-suffix.sh --date 20260801"
  [ "$output" = "-20260801-2" ]
}

@test "next-dated-suffix: it keeps counting past -2" {
  run bash -c "LARAOCI_TAG_EXISTS_CMD='case \$1 in *-20260801|*-20260801-2) exit 0;; *) exit 1;; esac' \
    next-dated-suffix.sh --date 20260801"
  [ "$output" = "-20260801-3" ]
}

@test "next-dated-suffix: ONE tag anywhere in the matrix bumps the whole release" {
  # The suffix is release-wide, not per image. Deciding it per merge job would
  # let runtime take -2 while cli takes -3 - one release, two dated tags, which
  # is the silent inconsistency §8 exists to prevent.
  run bash -c "LARAOCI_TAG_EXISTS_CMD='case \$1 in *scheduler:8.5-trixie-20260801) exit 0;; *) exit 1;; esac' \
    next-dated-suffix.sh --date 20260801"
  [ "$output" = "-20260801-2" ]
}

@test "next-dated-suffix: it probes every image and every supported version" {
  run bash -c "LARAOCI_TAG_EXISTS_CMD='echo \$1 >&2; exit 1' next-dated-suffix.sh --date 20260801 2>&1"
  # 6 images x 3 supported PHP versions
  [ "$(grep -c 'trixie-20260801$' <<<"$output")" -eq 18 ]
}

@test "next-dated-suffix: --date is required and shape-checked" {
  run bash -c "next-dated-suffix.sh"
  [ "$status" -eq 2 ]
  run bash -c "LARAOCI_TAG_EXISTS_CMD='exit 1' next-dated-suffix.sh --date 2026-08-01"
  [ "$status" -eq 2 ]
}

@test "next-dated-suffix: the seam refuses to run outside a test" {
  unset LARAOCI_TEST
  run bash -c "LARAOCI_TAG_EXISTS_CMD='exit 1' next-dated-suffix.sh --date 20260801"
  [ "$status" -eq 2 ]
  [[ "$output" == *"test-only seam"* ]]
}
