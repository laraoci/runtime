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
