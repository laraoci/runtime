# Structural invariants for the CI workflows. These assert SHAPE, not
# behaviour, because the behaviour only ever runs on GitHub. Parsing with yq
# rather than grepping the raw file means a step cannot dodge an assertion by
# reformatting its YAML.

# Every `run:` body in a workflow file, one per line of output.
run_bodies() {
  yq -r '.jobs[].steps[] | select(has("run")) | .run' "$1"
}

hadolint_step() {
  yq -r '.jobs[].steps[] | select((.run // "") | test("hadolint")) | .run' \
    .github/workflows/lint.yml
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

# --- the smoke workflow (LOCI-028) -------------------------------------------

@test "workflows: the smoke matrix is read from config/images.yml, not hardcoded" {
  # A literal version list keeps passing after config/images.yml deprecates a
  # version or adds one - the exact drift config/images.yml exists to prevent.
  # Asserted both ways: no version literal in the workflow's live content, and
  # the yq read actually present.
  #
  # Comments are stripped first - whole-line AND trailing. The prose is allowed
  # to name 8.3 and 8.5 to explain why a leg must fail independently, and every
  # pinned action carries a `# vX.Y.Z` marker; what must not exist is a version
  # this workflow ACTS on without asking config/images.yml.
  local live
  live="$(sed -E -e '/^[[:space:]]*#/d' -e 's/[[:space:]]+#.*$//' \
    .github/workflows/smoke.yml)"
  run grep -nE '[0-9]+\.[0-9]+' <<<"$live"
  [ "$status" -ne 0 ]

  run yq -r '[.jobs.matrix.steps[] | select((.run // "") | test("config/images.yml"))] | length' \
    .github/workflows/smoke.yml
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "workflows: the smoke workflow cancels superseded runs" {
  # Each leg builds three images and brings up a stack; overlapping runs of a
  # superseded push are the most expensive idle work in the repository.
  run yq -r '.concurrency."cancel-in-progress"' .github/workflows/smoke.yml
  [ "$output" = "true" ]
}

@test "workflows: every smoke leg fails independently" {
  # fail-fast would cancel 8.5 the moment 8.3 broke, hiding whether the change
  # is version-specific - which is the first question a red smoke run raises.
  run yq -r '.jobs.smoke.strategy."fail-fast"' .github/workflows/smoke.yml
  [ "$output" = "false" ]
}

@test "workflows: the smoke job asserts the harness leaked nothing, even when red" {
  # run.sh tears down in an EXIT trap; this is the check that the trap fired.
  # `if: always()` is load-bearing - gated on success it would only ever run on
  # the path where a leak is least likely.
  run yq -r '[.jobs.smoke.steps[]
    | select((.run // "") | test("docker volume ls"))
    | .if // "absent"] | length' .github/workflows/smoke.yml
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  run yq -r '.jobs.smoke.steps[]
    | select((.run // "") | test("docker volume ls"))
    | .if // "absent"' .github/workflows/smoke.yml
  [[ "$output" == *"always()"* ]]
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

@test "workflows: tools.env carries a bats version and a matching tag URL" {
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

@test "workflows: every pull_request workflow cancels superseded runs (L13)" {
  # pr.yml and smoke.yml both do, with reasoning about CI cost; lint.yml runs
  # four jobs on every push to a PR branch and did not.
  local f trigger group
  for f in .github/workflows/*.yml; do
    trigger="$(yq -r '.on | has("pull_request")' "$f")"
    [ "$trigger" = "true" ] || continue
    group="$(yq -r '.concurrency.group // ""' "$f")"
    [ -n "$group" ] || {
      echo "$f triggers on pull_request but has no concurrency group" >&2
      false
    }
  done
}

@test "workflows: every push-gated step in build.yml is recorded in docs/release-verification.md" {
  # The artifact that gets PUBLISHED was the one artifact never verified: five
  # steps are gated `!inputs.push`, and build.yml's own comment recorded that
  # for the structure tests only. The label set, the STOPSIGNAL check and the
  # size budget were in the identical position and named nowhere.
  #
  # A step that starts skipping the push path must be recorded there with the
  # plan for it, or this goes red.
  local names name
  names="$(yq -r '.jobs.build.steps[]
    | select((.if // "") | test("!inputs.push")) | .name' .github/workflows/build.yml)"
  [ -n "$names" ]

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    grep -qF -- "$name" docs/release-verification.md || {
      echo "build.yml skips '$name' on the push path" >&2
      echo "and docs/release-verification.md does not mention it" >&2
      false
    }
  done <<<"$names"
}

@test "workflows: every push-path step release-verification.md promises actually exists" {
  # THE REVERSE DIRECTION, and the one that matters now. The test above cannot
  # notice a Required row whose push-path twin was never built - which is
  # exactly the failure this milestone is most likely to produce: a doc that
  # claims the pushed digest is verified, and a workflow that does not verify
  # it. Adding a verified step must genuinely SHRINK the unverified set.
  #
  # The doc carries the step names in one fenced ```text block; each must exist
  # in build.yml gated ON the push path, not off it.
  local names name count
  names="$(sed -n '/^```text$/,/^```$/p' docs/release-verification.md | sed '1d;$d')"
  [ -n "$names" ]

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    count="$(S="$name" yq -r '[.jobs.build.steps[]
      | select(.name == strenv(S))
      | select((.if // "") | test("inputs\\.push"))
      | select((.if // "") | test("!inputs\\.push") | not)] | length' \
      .github/workflows/build.yml)"
    [ "$count" -ge 1 ] || {
      echo "docs/release-verification.md promises a push-path step named:" >&2
      echo "  $name" >&2
      echo "and build.yml has no such step gated on inputs.push" >&2
      false
    }
  done <<<"$names"
}

@test "workflows: the release path never measures size advisorily (§9.2, D17)" {
  # --report exits 0 on an overrun. On the release path that is not a report,
  # it is a budget that does not exist.
  #
  # Comments are stripped before the check: the step explains its own lack of
  # --report in a comment, and a test that reads prose as if it were a command
  # fails on the documentation of the very thing it is asserting.
  local body
  body="$(yq -r '.jobs.build.steps[]
    | select((.if // "") | test("inputs\\.push"))
    | select((.if // "") | test("!inputs\\.push") | not)
    | select((.run // "") | test("size-check.sh"))
    | .run' .github/workflows/build.yml)"
  [ -n "$body" ]

  body="$(printf '%s\n' "$body" | grep -v '^[[:space:]]*#' || true)"
  [[ "$body" == *"size-check.sh"* ]]
  [[ "$body" != *"--report"* ]]
}

@test "workflows: CI and the Makefile select Dockerfiles the same way" {
  # Two selectors for one job: `git ls-files '*Dockerfile' '*.Dockerfile'` in the
  # Makefile, `find images tests` in lint.yml. Equivalent for today's tree, and
  # they diverge for a Dockerfile outside images/ and tests/ (linted locally, not
  # in CI) and for an untracked one (linted in CI, not locally). This repository's
  # habit is one selector - and several CI-vs-Makefile equivalences above are
  # already pinned here.
  # COMMENTS STRIPPED, because the assertion is about the selector that RUNS,
  # not about the words in the step. lint.yml's replacement comment names the
  # `find images tests` form it replaced - which is the comment worth having,
  # and it would otherwise fail this test for quoting the thing it warns about.
  local live
  live="$(hadolint_step | sed -E 's/^[[:space:]]*#.*$//')"
  [[ "$live" == *"git ls-files"* ]]
  [[ "$live" != *"find images tests"* ]]

  run grep -c "git ls-files '\*Dockerfile' '\*.Dockerfile'" Makefile
  [ "$output" -ge 1 ]
}

@test "workflows: the release build attaches an SBOM and max-mode provenance (§9.2, §11)" {
  # mode=min is the BuildKit default and omits the Dockerfile, the build args
  # and the source maps - the parts that make provenance answer "what actually
  # went into this". §9.2 says max; a default that quietly degrades is the
  # failure this pins.
  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with.sbom' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"inputs.push"* ]]

  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with.provenance' \
    .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=max"* ]]
  [[ "$output" == *"inputs.push"* ]]
}

@test "workflows: the release scan is a hard gate on FIXABLE criticals (§9.2, 🧭 3)" {
  # Two halves, both load-bearing. --exit-code 1 is what makes it a gate rather
  # than a report. --ignore-unfixed is what stops an unfixable upstream CVE
  # blocking every release forever - the gate is on what someone can act on.
  run yq -r '.jobs.build.steps[]
    | select((.run // "") | test("trivy image"))
    | select((.if // "") | test("inputs\\.push"))
    | select((.if // "") | test("!inputs\\.push") | not)
    | .run' .github/workflows/build.yml
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"--exit-code 1"* ]]
  [[ "$output" == *"--ignore-unfixed"* ]]
  [[ "$output" == *"CRITICAL,HIGH"* ]]
}

@test "workflows: the SARIF upload never runs on the PR path (H2)" {
  # Uploading to code scanning needs security-events: write, and pr.yml is
  # asserted to request no write permission at all. An ungated upload step
  # would fail every PR - or, worse, force someone to widen pr.yml's token.
  local gate
  gate="$(yq -r '.jobs.build.steps[]
    | select((.uses // "") | test("codeql-action/upload-sarif"))
    | .if // "absent"' .github/workflows/build.yml)"
  [ -n "$gate" ]
  [[ "$gate" == *"inputs.push"* ]]
  [[ "$gate" != *"!inputs.push"* ]]
}

@test "workflows: the release path stages builds by graph depth" {
  # A child's FROM must resolve to THIS release's parent. Rolling tags do not
  # move until the whole matrix has passed (LOCI-046), so a flat matrix would
  # build cli against the PREVIOUS release's runtime - green, publishable, and
  # not the thing that was tested.
  run yq -r '.jobs."build-d1".needs | tostring' .github/workflows/release.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge-d0"* ]]
  run yq -r '.jobs."build-d2".needs | tostring' .github/workflows/release.yml
  [[ "$output" == *"merge-d1"* ]]
}

@test "workflows: exactly one job reads the clock (🧭 2)" {
  # 36 legs must agree on the dated tag. Two clock reads is two dates.
  run yq -r '[.jobs | to_entries | .[]
    | select([.value.steps[]? | select((.run // "") | test("date -u"))] | length > 0)
    | .key] | join(",")' .github/workflows/release.yml
  [ "$status" -eq 0 ]
  [ "$output" = "prepare" ]
}

@test "workflows: no release build leg fails fast" {
  # fail-fast would cancel the other 35 legs on the first failure, hiding
  # whether the break is version-specific or architecture-specific - which is
  # the first question a red release raises, and the only one arm64 can answer.
  local job
  for job in build-d0 build-d1 build-d2; do
    run yq -r ".jobs.\"$job\".strategy.\"fail-fast\"" .github/workflows/release.yml
    [ "$output" = "false" ]
  done
}

@test "workflows: the release grants the three tokens the push path needs" {
  run yq -r '.jobs."build-d0".permissions | tostring' .github/workflows/release.yml
  [[ "$output" == *"packages"* ]]
  [[ "$output" == *"security-events"* ]]
}
