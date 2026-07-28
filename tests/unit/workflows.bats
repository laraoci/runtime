# Structural invariants for the CI workflows. These assert SHAPE, not
# behaviour, because the behaviour only ever runs on GitHub. Parsing with yq
# rather than grepping the raw file means a step cannot dodge an assertion by
# reformatting its YAML.

# Every `run:` body in a workflow file, one per line of output.
run_bodies() {
  yq -r '.jobs[].steps[] | select(has("run")) | .run' "$1"
}

@test "workflows: no GitHub expression is interpolated into a run: body (H1)" {
  local f out
  for f in .github/workflows/*.yml; do
    out="$(run_bodies "$f" | grep -n '\${{' || true)"
    if [ -n "$out" ]; then
      echo "$f interpolates \${{ }} into a run: body - pass it through env: instead:" >&2
      echo "$out" >&2
      false
    fi
  done
}

@test "workflows: the PR workflow requests no write permission (H2)" {
  run yq -r '[.permissions | to_entries | .[] | select(.value != "read" and .value != "none")] | length' \
    .github/workflows/pr.yml
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "workflows: PR builds never write the shared build cache (H3)" {
  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with["cache-to"]' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  # Must be gated on inputs.push; an unconditional type=gha lets an unmerged PR
  # seed layers that a later main build restores.
  [[ "$output" == *"inputs.push"* ]]
}

@test "workflows: the PR workflow cancels superseded runs (L13)" {
  run yq -r '.concurrency."cancel-in-progress"' .github/workflows/pr.yml
  [ "$output" = "true" ]
}

@test "workflows: every multi-line run: body sets -euo pipefail (M3)" {
  local f out
  for f in .github/workflows/*.yml; do
    out="$(yq -r '
      .jobs[].steps[]
      | select(has("run"))
      | select(.run | contains("\n"))
      | select(.run | test("set -euo pipefail") | not)
      | .name // "<unnamed step>"' "$f")"
    if [ -n "$out" ]; then
      echo "$f has multi-line run: steps that do not set -euo pipefail:" >&2
      echo "$out" >&2
      false
    fi
  done
}

@test "workflows: the debian suite is never hardcoded in build.yml (M2)" {
  # Five hardcoded 'trixie' literals used to make config/images.yml's documented
  # per-version override silently inert.
  run grep -c 'trixie' .github/workflows/build.yml
  [ "$output" -eq 0 ]
}

@test "workflows: build.yml guards the load path against a multi-platform list (M7)" {
  # BuildKit cannot load a manifest list into the Docker daemon; the reusable
  # workflow accepts a comma-separated list, so the combination must fail fast.
  run yq -r '[.jobs.build.steps[] | select((.run // "") | test("cannot be loaded|manifest list"))] | length' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "workflows: the load path materialises the ancestor chain (🧭 5)" {
  # Every image below `runtime` is FROM a LaraOCI reference that exists in no
  # registry until M4 pushes one, and each matrix leg is its own job on its own
  # runner - so the load path has to build its parents before its own FROM is
  # resolved, or the leg fails with a bare "not found".
  run yq -r '[.jobs.build.steps[] | select((.run // "") | test("build-chain.sh"))] | length' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "workflows: the ancestor build is gated on the load path (🧭 5)" {
  # On the push path the parents come from the registry, and rebuilding them
  # per leg would be pure waste.
  run yq -r '.jobs.build.steps[] | select((.run // "") | test("build-chain.sh")) | .if' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs.push"* ]]
}

@test "workflows: the load path uses a builder that can see local images (🧭 5)" {
  # The docker-container driver has its own store and cannot see an image loaded
  # into the daemon, so leaving this at the action's default silently breaks
  # every child image - the failure looks like a registry problem, not a driver
  # one, which is exactly why it is pinned here.
  run yq -r '.jobs.build.steps[] | select((.uses // "") | test("setup-buildx-action")) | .with.driver' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs.push"* ]]
}

@test "workflows: the gha cache is imported only where the driver supports it (🧭 5)" {
  # type=gha needs the docker-container driver; an unconditional cache-from
  # would fail every PR leg once the driver switch above is in place.
  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with["cache-from"]' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs.push"* ]]
}

@test "workflows: no build arg is passed to an image that does not declare it (🧭 5)" {
  # PARENT_REF belongs to a child, BASE_DIGEST to the root. Listing both
  # unconditionally makes BuildKit warn on every leg about an unused build
  # argument, and a warning that is always there is a warning nobody reads.
  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with["build-args"]' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"steps.args.outputs"* ]]
}

@test "workflows: no CI tool is downloaded without a checksum (L5)" {
  local f out
  for f in .github/workflows/*.yml; do
    out="$(run_bodies "$f" | grep -n 'curl ' || true)"
    if [ -n "$out" ]; then
      echo "$f calls curl directly - use bin/fetch-tool.sh so the asset is verified:" >&2
      echo "$out" >&2
      false
    fi
  done
}

# --- bats-runner pinning (M5 submodule -> pinned tarball migration) ----------
# These lock in the migration away from the vendored bats-core submodule. The
# submodule was removed because it pulled ~200 files of third-party code into
# lint scope and forced `submodules: true` on every checkout; the replacement
# fetches an SHA-pinned tarball through bin/fetch-bats.sh. Each invariant below
# is a way that migration could silently regress.

@test "workflows: bats.env pins the runner by 64-hex SHA-256, not just a version (L5)" {
  # A version alone prevents drift but not substitution - a tagged asset can be
  # replaced in place. The hash is the trust anchor, so it must be present and
  # well-formed, matching how shfmt/yq/hadolint are pinned.
  [ -f tests/bats.env ]
  # shellcheck disable=SC1091
  run bash -c 'set -a; . tests/bats.env; printf "%s" "$BATS_SHA256"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "workflows: bats.env carries a version and a matching tag URL" {
  # shellcheck disable=SC1091
  . tests/bats.env
  [ -n "$BATS_VERSION" ]
  # The URL must reference the same version it claims to pin, or the hash guards
  # a different artefact than the one named.
  [[ "$BATS_URL" == *"v${BATS_VERSION}"* ]]
}

@test "workflows: no workflow re-introduces the bats submodule checkout" {
  # 'submodules: true' was dropped from every checkout when the submodule went.
  # Its return means someone re-vendored bats or wired a new submodule without
  # updating this migration.
  local f out
  for f in .github/workflows/*.yml; do
    out="$(yq -r '.jobs[].steps[] | select(.uses // "" | test("actions/checkout")) | .with.submodules // "absent"' "$f" 2>/dev/null | grep -v '^absent$' || true)"
    if [ -n "$out" ]; then
      echo "$f still requests submodules on checkout: $out" >&2
      false
    fi
  done
}

@test "workflows: nothing references the old tests/bats submodule path" {
  # Covers the runner invocation AND the hadolint prune that only existed to
  # skip the vendored tree. Grep the raw files: a lingering path anywhere is a
  # dangling reference now that tests/bats is gone.
  run grep -rn 'tests/bats' .github/workflows/
  [ "$status" -ne 0 ]
}

@test "workflows: the submodule is fully deregistered (no .gitmodules entry)" {
  # A .gitmodules stanza left behind re-materialises the submodule on the next
  # `git submodule update`, quietly undoing the migration.
  if [ -f .gitmodules ]; then
    run git config --file .gitmodules --get-regexp '^submodule\.tests/bats\.'
    [ "$status" -ne 0 ]
  fi
}

@test "workflows: the unit-test job fetches bats through the verified helper" {
  # The bats job must run the suite via bin/fetch-bats.sh (which verifies the
  # hash), not a bare runner path. Asserts the migration's mechanism is actually
  # wired, not just that the old path is absent.
  run yq -r '[.jobs.bats.steps[] | select((.run // "") | test("fetch-bats"))] | length' \
    .github/workflows/lint.yml
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "workflows: fetch-bats.sh exists, is executable, and is checksum-guarded" {
  # It downloads with curl, which test \"no CI tool ... without a checksum\"
  # forbids inside workflow run: bodies - so it MUST live in bin/ and MUST carry
  # the sha256 verification itself, or the curl simply moved somewhere unchecked.
  [ -x bin/fetch-bats.sh ]
  run grep -c 'sha256sum -c' bin/fetch-bats.sh
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
