#!/usr/bin/env bats

@test "php-versions: excludes deprecated by default" {
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/php-versions.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"8.5"* ]]
  [[ "$output" == *"8.3"* ]]
  [[ "$output" == *"8.4"* ]]
}

@test "php-versions: --include-deprecated includes them, in file order" {
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/php-versions.sh --include-deprecated"
  [ "$(echo "$output" | tr '\n' ' ')" = "8.3 8.4 8.5 " ]
}

@test "php-versions: --with-status carries the status and the freeze date" {
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/php-versions.sh --include-deprecated --with-status"
  [[ "$output" == *"8.5"$'\t'"deprecated"$'\t'"2026-06-30"* ]]
  [[ "$output" == *"8.4"$'\t'"supported"$'\t'* ]]
}
