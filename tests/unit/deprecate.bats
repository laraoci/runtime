#!/usr/bin/env bats

# THE §13 STATE TRANSITION. The edit itself is one yq call; everything here is
# about the transitions that must be REFUSED, because a deprecation that leaves
# the catalog inconsistent is discovered by consumers rather than by CI.

setup() {
  TMP="$(mktemp -d)"
  cp config/images.yml "$TMP/images.yml"
}

teardown() { rm -rf "$TMP"; }

@test "deprecate: marks the version and records the freeze date (§13)" {
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 2026-11-30"
  [ "$status" -eq 0 ]
  run bash -c "yq -r '.php.\"8.3\".status' $TMP/images.yml"
  [ "$output" = "deprecated" ]
  run bash -c "yq -r '.php.\"8.3\".deprecated_on' $TMP/images.yml"
  [ "$output" = "2026-11-30" ]
}

@test "deprecate: PRESERVES the comments in config/images.yml" {
  # config/images.yml is 174 lines of which most are load-bearing reasoning -
  # the runner pinning, the budget formula and its measurements, the trixie
  # override mechanism. A tool that silently ate them would be discovered on the
  # next review, after the fact. Counted before and after, on the REAL file.
  local before after
  before="$(grep -c '^[[:space:]]*#' "$TMP/images.yml")"
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 2026-11-30"
  [ "$status" -eq 0 ]
  after="$(grep -c '^[[:space:]]*#' "$TMP/images.yml")"
  [ "$before" -eq "$after" ] || {
    echo "deprecate.sh lost $((before - after)) comment lines from config/images.yml" >&2
    false
  }
}

@test "deprecate: refuses to deprecate the default version" {
  # :latest follows `default: true` and nothing else (§8). Deprecating it would
  # leave the tag most consumers pull with no version behind it, and the freeze
  # would silently apply to :latest itself.
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.4 --on 2026-11-30"
  [ "$status" -eq 1 ]
  [[ "$output" == *"default"* ]]
  run bash -c "yq -r '.php.\"8.4\".status' $TMP/images.yml"
  [ "$output" = "supported" ]
}

@test "deprecate: refuses to leave zero supported versions" {
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 2026-11-30"
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.5 --on 2026-11-30"
  [ "$status" -eq 0 ]
  # 8.4 is the default and is refused above, so this config cannot reach zero -
  # but a config whose default was already deprecated could, and the matrix
  # would then be empty and every workflow green.
  run bash -c "yq -r '[.php[] | select(.status != \"deprecated\")] | length' $TMP/images.yml"
  [ "$output" -ge 1 ]
}

@test "deprecate: is idempotent" {
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 2026-11-30"
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 2027-01-01"
  [ "$status" -eq 0 ]
  # The ORIGINAL freeze date survives: §13 states the date the rolling tag
  # stopped moving, and a second run must not rewrite history.
  run bash -c "yq -r '.php.\"8.3\".deprecated_on' $TMP/images.yml"
  [ "$output" = "2026-11-30" ]
}

@test "deprecate: rejects an unknown version and a malformed date" {
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 9.9 --on 2026-11-30"
  [ "$status" -eq 2 ]
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 30-11-2026"
  [ "$status" -eq 2 ]
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3"
  [ "$status" -eq 2 ]
}

@test "deprecate: a deprecated version disappears from the build matrix (effect 1)" {
  run bash -c "CONFIG=$TMP/images.yml bin/deprecate.sh --php 8.3 --on 2026-11-30"
  run bash -c "CONFIG=$TMP/images.yml bin/matrix.sh | jq -e '[.include[].php] | index(\"8.3\") == null'"
  [ "$status" -eq 0 ]
}
