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

@test "affected: a structure-test config rebuilds exactly its image (M4)" {
  # tests/structure/<name>.yaml only runs inside a build leg for <name>, so a
  # PR that edits one must build that image or the new assertions never run.
  run affected "tests/structure/runtime.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "runtime" ]
}

@test "affected: a structure-test config does NOT rebuild descendants (M4)" {
  # cli has its own config; runtime.yaml says nothing about it.
  run affected "tests/structure/runtime.yaml"
  [[ "$output" != *"cli"* ]]
}

@test "affected: the shared structure contract rebuilds all six (M2)" {
  # _common.yaml runs on every image's leg, so a change to it that rebuilt only
  # one would leave five images asserting the old contract - and passing.
  run affected "tests/structure/_common.yaml"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "builder cli fpm queue runtime scheduler " ]
}

@test "affected: the shared contract is matched by name, not by falling through (M2)" {
  # The be-conservative fallback gives the same six images for any unrecognised
  # config name, so the count alone cannot tell the two paths apart. A config
  # for an image that DOES exist must still narrow to that one image - if this
  # ever returns six, the _common case has swallowed the specific one.
  run affected "tests/structure/cli.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "cli" ]
}

@test "affected: unit tests, fixtures and probes still rebuild nothing" {
  run affected "tests/unit/affected.bats" "tests/fixtures/budgets.yml" "tests/probe/no-extra.Dockerfile"
  [ "$status" -eq 0 ]
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

@test "affected: an unresolvable --base fails loudly, never as 'nothing to build'" {
  # mapfile < <(cmd) does not observe cmd's exit status and set -e does not reach
  # into a process substitution, so a failed git diff used to leave `changed`
  # empty and exit 0 - which pr.yml reads as "no image is affected", skips the
  # build job, and passes pr-required. A green gate on a PR that built nothing.
  run bin/affected.sh --base origin/laraoci-no-such-ref
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot determine affected images"* ]]
}

@test "affected: a genuinely empty diff is still a clean exit 0" {
  # The failure above must not be reached by making every empty result fatal:
  # a docs-only PR legitimately affects nothing and must stay green.
  #
  # HEAD..HEAD, not HEAD. A bare `git diff HEAD` includes the WORKING TREE, so
  # this assertion would pass or fail depending on what the developer running it
  # happens to have uncommitted - green on a clean checkout, red the moment you
  # edit bin/anything, which is precisely when you are running it. The
  # commit-to-commit form is empty by construction on any tree.
  run bin/affected.sh --base HEAD..HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
