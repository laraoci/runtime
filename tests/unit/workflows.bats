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

@test "workflows: no CI tool is downloaded without a checksum (L5)" {
  local f out
  for f in .github/workflows/*.yml; do
    out="$(run_bodies "$f" | grep -n 'curl ' || true)"
    if [ -n "$out" ]; then
      echo "$f calls curl directly - use bin/fetch-tools.sh so the asset is verified:" >&2
      echo "$out" >&2
      false
    fi
  done
}

# --- bats-runner pinning (M5 submodule -> pinned tarball migration) ----------
# These lock in the migration away from the vendored bats-core submodule. The
# submodule was removed because it pulled ~200 files of third-party code into
# lint scope and forced `submodules: true` on every checkout; the replacement
# fetches a SHA-pinned tarball through bin/fetch-bats.sh. Each invariant below
# is a way that migration could silently regress.

@test "workflows: tools.env pins the runner by 64-hex SHA-256, not just a version (L5)" {
  # A version alone prevents drift but not substitution - a tagged asset can be
  # replaced in place. The hash is the trust anchor, so it must be present and
  # well-formed, matching how shfmt/yq/hadolint are pinned.
  [ -f tools.env ]
  # shellcheck disable=SC1091
  run bash -c 'set -a; . tools.env; printf "%s" "$BATS_SHA256"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "workflows: bats.env carries a version and a matching tag URL" {
  # shellcheck disable=SC1091
  . tools.env
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

@test "workflows: the unit-test job fetches bats through the verified fetcher" {
  # The bats job must obtain the runner via bin/fetch-tools.sh --path bats (which
  # verifies the hash), not a bare runner path. Asserts the mechanism is wired,
  # not just that the old submodule path is absent.
  run yq -r '[.jobs.bats.steps[] | select((.run // "") | test("fetch-tools.sh --path bats"))] | length' \
    .github/workflows/lint.yml
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "workflows: the pinned fetcher is checksum-guarded and lives in bin/" {
  # bats and every other tool are fetched by bin/fetch-tools.sh, which downloads
  # with curl - so it MUST carry the sha256 verification itself, or the curl
  # simply moved somewhere unchecked. (fetch-bats.sh was folded into it.)
  [ -x bin/fetch-tools.sh ]
  [ ! -e bin/fetch-bats.sh ]
  run grep -c 'sha256sum -c' bin/fetch-tools.sh
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
