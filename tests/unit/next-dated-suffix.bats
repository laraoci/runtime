# `run --separate-stderr` needs 1.5.0. tools.env pins bats at 1.14.0, so this is
# satisfied by construction; declaring it is what silences BW02 and states the
# floor for anyone running the suite under their own copy.
bats_require_minimum_version 1.5.0

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

@test "next-dated-suffix: a deprecated version is not probed by default (§13)" {
  # The scheduled rebuild never passes the flag, so it must not so much as ask
  # the registry about a deprecated version's dated tags - the same default that
  # keeps it out of the build matrix.
  run bash -c "CONFIG=tests/fixtures/deprecated.yml \
    LARAOCI_TAG_EXISTS_CMD='echo \$1 >&2; exit 1' \
    next-dated-suffix.sh --date 20260801 2>&1"
  [ "$status" -eq 0 ]
  # 6 images x 2 supported versions; 8.5 is deprecated in this fixture.
  [ "$(grep -c 'trixie-20260801$' <<<"$output")" -eq 12 ]
  [ "$(grep -c ':8\.5-' <<<"$output")" -eq 0 ]
}

@test "next-dated-suffix: --include-deprecated probes it too (§8)" {
  # THE REASON THE FLAG IS THREADED HERE AT ALL. A deliberate release of a
  # deprecated version publishes dated tags for it, and this script decides which
  # suffix is free. Probing a narrower set than the release WRITES is how a
  # release picks -20260801 while runtime:8.5-trixie-20260801 already exists -
  # and §8 forbids overwriting a dated tag, irreversibly.
  run bash -c "CONFIG=tests/fixtures/deprecated.yml \
    LARAOCI_TAG_EXISTS_CMD='echo \$1 >&2; exit 1' \
    next-dated-suffix.sh --date 20260801 --include-deprecated 2>&1"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'trixie-20260801$' <<<"$output")" -eq 18 ]
  [ "$(grep -c ':8\.5-' <<<"$output")" -eq 6 ]
}

@test "next-dated-suffix: a deprecated version's existing tag bumps the suffix" {
  # The consequence made concrete: with the flag, an 8.5 dated tag that already
  # exists moves the WHOLE release to -2, exactly as one on a supported version
  # does. Without the flag it is invisible, which is the bug.
  local seam="case \$1 in *8.5*-20260801) exit 0;; *) exit 1;; esac"
  run bash -c "CONFIG=tests/fixtures/deprecated.yml \
    LARAOCI_TAG_EXISTS_CMD='$seam' \
    next-dated-suffix.sh --date 20260801 --include-deprecated"
  [ "$status" -eq 0 ]
  [ "$output" = "-20260801-2" ]

  run bash -c "CONFIG=tests/fixtures/deprecated.yml \
    LARAOCI_TAG_EXISTS_CMD='$seam' \
    next-dated-suffix.sh --date 20260801"
  [ "$output" = "-20260801" ]
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

@test "next-dated-suffix: an unanswerable probe stops the release, it does not guess" {
  # Exit 2 from the seam means "I could not tell". The old code had no such
  # state: every non-zero exit read as "free", so a 401 on a private package
  # produced the bare suffix and the release overwrote an immutable dated tag.
  #
  # SPLIT STREAMS, deliberately. "No suffix was emitted" is a statement about
  # STDOUT - that is the script's whole output contract, and the release reads it
  # with `$(...)`. Asserting the date appears nowhere in the merged streams would
  # be unsatisfiable: the error names the tag it could not read, and that tag
  # ends in the date. An error message good enough to act on would fail the test.
  run --separate-stderr bash -c \
    "LARAOCI_TAG_EXISTS_CMD='exit 2' next-dated-suffix.sh --date 20260801"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot determine"* ]]
}

@test "next-dated-suffix: an unanswerable probe on ONE tag stops the whole release" {
  # Not "skip that one and carry on". A probe that cannot see part of the
  # namespace cannot conclude anything about the suffix for any of it.
  run --separate-stderr bash -c \
    "LARAOCI_TAG_EXISTS_CMD='case \$1 in *scheduler:8.5-trixie-20260801) exit 2;; *) exit 1;; esac' \
    next-dated-suffix.sh --date 20260801"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"scheduler:8.5-trixie-20260801"* ]]
}
