affected() { printf '%s\n' "$@" | bin/affected.sh; }

@test "affected: images/runtime change rebuilds all six" {
  run affected "images/runtime/Dockerfile"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "builder cli fpm queue runtime scheduler " ]
}

@test "affected: images/queue change rebuilds queue only" {
  run affected "images/queue/Dockerfile"
  [ "$output" = "queue" ]
}

@test "affected: images/cli change rebuilds cli and its descendants" {
  run affected "images/cli/Dockerfile"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "cli queue scheduler " ]
}

@test "affected: config change rebuilds all six" {
  run affected "config/images.yml"
  [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "affected: bin change rebuilds all six" {
  run affected "bin/matrix.sh"
  [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "affected: build workflow change rebuilds all six" {
  run affected ".github/workflows/build.yml"
  [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "affected: docs-only change rebuilds nothing" {
  run affected "docs/readme.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "affected: tests/structure change rebuilds nothing" {
  run affected "tests/structure/runtime.yaml"
  [ -z "$output" ]
}

@test "affected: a deleted image file still triggers a rebuild" {
  # affected.sh works from a path list; a deletion is just a path, so the
  # queue rebuild fires exactly as for a modification.
  run affected "images/queue/Dockerfile"
  [ "$output" = "queue" ]
}

@test "affected: multiple paths union their image sets" {
  run affected "images/queue/Dockerfile" "images/scheduler/Dockerfile"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "queue scheduler " ]
}

@test "affected: --json emits a JSON array" {
  run bash -c "printf '%s\n' images/queue/Dockerfile | bin/affected.sh --json"
  [ "$output" = '["queue"]' ]
}

@test "affected: --json on nothing emits []" {
  run bash -c "printf '%s\n' docs/x.md | bin/affected.sh --json"
  [ "$output" = "[]" ]
}
