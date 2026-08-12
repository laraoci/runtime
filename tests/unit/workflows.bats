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

@test "workflows: every published manifest list is signed, recursively (§11)" {
  # -r signs each child manifest as well as the index. Without it a consumer
  # who pins a per-platform digest - the supply-chain-strict path §8 recommends
  # - finds no signature at all.
  run yq -r '.jobs.merge.steps[] | select((.run // "") | test("cosign sign")) | .run' \
    .github/workflows/merge.yml
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"-r"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "workflows: the signing job requests id-token: write" {
  # Keyless signing IS the OIDC token. Without it cosign falls back to an
  # interactive browser flow and the job hangs until it times out.
  run yq -r '.jobs."merge-d0".permissions."id-token"' .github/workflows/release.yml
  [ "$output" = "write" ]
}

@test "workflows: release-required aggregates EVERY build and merge job" {
  # The same pattern as pr-required and smoke-required, reached from the
  # release side. A job missing from `needs` is a leg whose failure cannot stop
  # the repoint - which is the whole of LOCI-046.
  local needs
  needs="$(yq -r '.jobs."release-required".needs | join(",")' .github/workflows/release.yml)"
  local job
  for job in build-d0 merge-d0 build-d1 merge-d1 build-d2 merge-d2; do
    [[ "$needs" == *"$job"* ]] || {
      echo "release-required does not aggregate $job" >&2
      false
    }
  done
  run yq -r '.jobs."release-required".if' .github/workflows/release.yml
  [[ "$output" == *"always()"* ]]
}

@test "workflows: nothing repoints a rolling tag before the whole matrix passes" {
  # A rolling tag moved per-leg leaves :latest pointing at a runtime that built
  # beside a queue that did not - a set nobody ever tested together.
  run yq -r '.jobs.repoint.needs | join(",")' .github/workflows/release.yml
  [[ "$output" == *"release-required"* ]]

  # And it must be the ONLY job that asks for rolling tags.
  run bash -c "yq -r '.jobs | to_entries | .[]
    | select([.value.steps[]? | select((.run // \"\") | test(\"kind rolling\"))] | length > 0)
    | .key' .github/workflows/release.yml"
  [ "$output" = "repoint" ]
}

@test "workflows: the repoint resolves every dated digest before moving anything" {
  # Phase 1 / phase 2. Every failure knowable in advance is discovered while
  # zero rolling tags have moved.
  run yq -r '[.jobs.repoint.steps[] | .name] | join("|")' .github/workflows/release.yml
  [[ "$output" == *"Resolve"* ]]
  [[ "$output" == *"Move"* ]]
}

@test "workflows: only a stable release repoints the rolling tags" {
  # A prerelease (v1.0.0-rc.1) and a branch dispatch both publish immutable
  # dated tags but must NOT move :latest / :8.x. The gate reads a fact resolved
  # once in prepare, so both the dry_run reason and the prerelease reason are
  # visible in one condition.
  run yq -r '.jobs.repoint.if' .github/workflows/release.yml
  [[ "$output" == *"is_stable_release"* ]]
  [[ "$output" == *"dry_run"* ]]

  # prepare must actually export the fact the gate depends on, or the gate is a
  # comparison against an empty string that is never 'true' - a repoint that can
  # never run, which no other test would catch.
  run yq -r '.jobs.prepare.outputs.is_stable_release' .github/workflows/release.yml
  [[ "$output" == *"steps.channel.outputs.is_stable_release"* ]]
}

@test "workflows: the release channel classifies the three ref shapes correctly" {
  # Extract the case body from the channel step and drive it with each ref shape,
  # so the classification is tested rather than eyeballed. A stable tag repoints;
  # a prerelease tag and a branch dispatch do not.
  local body
  body="$(yq -r '.jobs.prepare.steps[] | select(.id == "channel") | .run' .github/workflows/release.yml)"
  [ -n "$body" ]

  classify() {
    # Run the step body with REF and IS_REBUILD set and GITHUB_OUTPUT captured,
    # then echo the resolved value. Two arguments, because the channel now has
    # two inputs: the ref shape, and whether this is a scheduled rebuild (🧭 2).
    local ref="$1" rebuild="${2:-false}" out
    out="$(mktemp)"
    REF="$ref" IS_REBUILD="$rebuild" GITHUB_OUTPUT="$out" bash -c "$body" >/dev/null 2>&1
    grep -oE 'is_stable_release=(true|false)' "$out" | tail -n1 | cut -d= -f2
    rm -f "$out"
  }

  [ "$(classify refs/tags/v1.0.0)" = "true" ]
  [ "$(classify refs/tags/v1.2.3)" = "true" ]
  [ "$(classify refs/tags/v1.0.0-rc.1)" = "false" ]
  [ "$(classify refs/tags/v1.0.0-beta.2)" = "false" ]
  [ "$(classify refs/heads/main)" = "false" ]

  # 🧭 2. A schedule event carries NO TAG - its ref is refs/heads/main, which the
  # line above correctly classifies as "does not repoint". §9.3 is explicit that
  # the rebuild DOES produce a new dated tag and DOES repoint the rolling tags,
  # so the fact is carried by an explicit input rather than sniffed from a ref
  # that cannot express it.
  [ "$(classify refs/heads/main true)" = "true" ]

  # And an empty string - what `inputs.is_rebuild` renders as on a TAG PUSH,
  # where the inputs context does not exist - must not be read as true.
  [ "$(classify refs/tags/v1.0.0-rc.1 '')" = "false" ]
}

@test "workflows: a prerelease is not published as the Latest GitHub release" {
  # gh release create marks the latest by default; an rc surfaced as 'Latest'
  # on the repo homepage defeats the point of a quiet shakedown. The publish
  # step must pass --prerelease off the same stable-release fact.
  local run_body
  run_body="$(yq -r '.jobs.notes.steps[] | select(.name == "Publish the release") | .run' .github/workflows/release.yml)"
  [[ "$run_body" == *"--prerelease"* ]]
  [[ "$run_body" == *"IS_STABLE"* ]]
}

@test "workflows: a dry run cannot resolve to the production namespace" {
  # THE GATE 2 FOOTGUN. dry_run only skips the repoint - the 18 merge jobs still
  # write IMMUTABLE dated tags and cosign still signs them. §8 forbids
  # overwriting a dated tag, so a dispatch that left registry_namespace blank
  # publishes a bogus release into ghcr.io/laraoci that CANNOT be cleaned up by
  # re-running. The whole safety of a staging run rested on an operator
  # remembering one optional text field.
  #
  # The refusal belongs in `prepare`, because that is the only place it can stop
  # the run while zero legs have started.
  run yq -r '.jobs.prepare.steps[] | select(.id == "ns") | .env | has("DRY_RUN")' \
    .github/workflows/release.yml
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  # And it must REFUSE, not warn: a notice on a job that keeps going publishes
  # exactly as much as no check at all.
  run yq -r '.jobs.prepare.steps[] | select(.id == "ns") | .run' \
    .github/workflows/release.yml
  [[ "$output" == *"exit 1"* ]]
}

@test "workflows: every --ref argument is an expansion, never a literal" {
  # `--ref "IMAGE_REF"` - one missing $ - reached the daemon as an image NAME
  # and died with `repository name (library/IMAGE_REF) must be lowercase`, on
  # the step that is the only place STOPSIGNAL is asserted.
  #
  # Neither linter can see it: a quoted bare word is a valid string to
  # shellcheck, and actionlint does not know what --ref means. The reference
  # arguments are the ones worth checking by hand, because every one of them
  # names an image that a verification step is about to trust.
  local bad
  bad="$(grep -hoE -- '--ref [^ ]+' .github/workflows/*.yml | grep -vE -- '--ref "?\$' || true)"
  [ -z "$bad" ] || {
    echo "a --ref argument is a literal, not an expansion:" >&2
    echo "$bad" >&2
    false
  }
}

@test "workflows: no expression uses a falsy middle operand (the && '' || trap)" {
  # GitHub's ternary idiom `a && b || c` returns c whenever b is FALSY, and '',
  # "", 0 and false all are. So `inputs.push && '' || image_ref` does not mean
  # "empty when pushing" - it means image_ref, ALWAYS, on both paths.
  #
  # That shipped as build.yml's `tags:` and made every release leg die with
  # `can't push tagged ref ... by digest`, because push-by-digest and a tag
  # cannot be combined. It is invisible to actionlint, which type-checks the
  # expression without evaluating its truthiness.
  #
  # The fix is always to invert so the NON-EMPTY value is the middle operand.
  #
  # Comments are stripped first: the fixed line documents the trap it avoids by
  # quoting it, and a test that reads prose as if it were an expression fails on
  # the documentation of the very thing it is asserting.
  local bad
  bad="$(grep -rnE -- "&& *('' *|\"\" *|0 +|false +)\|\|" .github/workflows/*.yml \
    | grep -vE '^[^:]+:[0-9]+: *#' || true)"
  [ -z "$bad" ] || {
    echo "an expression falls through to its right operand unconditionally:" >&2
    echo "$bad" >&2
    false
  }
}

@test "workflows: a reusable workflow never keys anything on strategy.job-index" {
  # `strategy` describes the job RUNNING the workflow, and inside a called
  # workflow that is not the caller's matrix - job-index reads as 0 in every
  # leg. build.yml named its digest artifact with it, so both platforms of an
  # image x php uploaded under ONE name, download-artifact resolved that name to
  # one artifact, and merge stopped with "expected 2 platform digests, found 1"
  # with all 36 legs green. Measured on run 31481618763.
  #
  # Nothing else can catch this: the expression is valid, actionlint accepts it,
  # and the damage appears in a different job. So it is banned outright in any
  # workflow_call file - the platform or another real input is the honest key.
  #
  # Comments stripped: the upload step explains the trap by naming it, and a
  # test that reads prose as if it were an expression fails on the documentation
  # of the very thing it is asserting.
  local f bad
  for f in .github/workflows/*.yml; do
    [ "$(yq -r '.on | has("workflow_call")' "$f")" = "true" ] || continue
    bad="$(grep -n 'strategy\.job-index' "$f" | grep -vE '^[0-9]+: *#' || true)"
    [ -z "$bad" ] || {
      echo "$f is a reusable workflow and keys on strategy.job-index:" >&2
      echo "$bad" >&2
      false
    }
  done
}

@test "workflows: every release job that logs in to GHCR declares a packages scope" {
  # A job that logs in and then reads a manifest with packages: none gets a 401,
  # and `imagetools inspect` reports a 401 the same way it reports a 404: exit 1.
  # bin/next-dated-suffix.sh turns that into "the dated tag is free", which is how
  # a release overwrites an immutable tag. The scope is the half of that fix that
  # lives here.
  local jobs job scope
  jobs="$(yq -r '.jobs | to_entries | .[]
    | select([.value.steps[]? | select((.uses // "") | test("docker/login-action"))] | length > 0)
    | .key' .github/workflows/release.yml)"
  [ -n "$jobs" ]
  for job in $jobs; do
    scope="$(JOB="$job" yq -r '.jobs[strenv(JOB)].permissions.packages // "ABSENT"' \
      .github/workflows/release.yml)"
    if [ "$scope" = "ABSENT" ]; then
      echo "release.yml job '$job' logs in to GHCR but declares no packages scope." >&2
      echo "A denied read is indistinguishable from a 404 - see bin/next-dated-suffix.sh." >&2
      false
    fi
  done
}

@test "workflows: trivy is installed on every path that uses it" {
  # The install was gated on structure_test while two of the three consumers -
  # the SARIF scan and the hard gate - are gated on push. A caller with
  # push: true, structure_test: false would reach the security gate and die on
  # `trivy: command not found`: the gate failing for a reason that is not a CVE.
  local install
  install="$(yq -r '.jobs.build.steps[]
    | select((.name // "") | test("Install the pinned trivy"))
    | .if' .github/workflows/build.yml)"
  [ -n "$install" ]
  [[ "$install" == *"inputs.push"* ]]
  [[ "$install" == *"inputs.structure_test"* ]]
  [[ "$install" == *"||"* ]]
}

@test "workflows: merge.yml assembles a deprecated version, and only its dated tags (§13)" {
  # MERGE IS ASSEMBLY, NOT POLICY. Whether a deprecated version publishes was
  # decided in `prepare`; by the time this job runs, its legs have already
  # pushed. Without the flag, bin/matrix.sh returns zero platforms for it and
  # merge exits 1 - so a deliberate release (include_deprecated) would build,
  # push, and then silently never receive a dated tag, which is trap 2's
  # "a deliberate release can still publish" failing at the last step.
  local bodies
  bodies="$(yq -r '.jobs.merge.steps[] | select(has("run")) | .run' \
    .github/workflows/merge.yml)"
  # Comments stripped and backslash continuations joined FIRST: the call sites
  # span several lines each, and the surrounding prose mentions both script
  # names, so a naive grep matches the documentation rather than the code.
  local code call
  code="$(grep -vE '^[[:space:]]*#' <<<"$bodies" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}')"
  while IFS= read -r call; do
    [ -z "$call" ] && continue
    [[ "$call" == *"--include-deprecated"* ]] || {
      echo "merge.yml calls a version-filtered script without --include-deprecated:" >&2
      echo "  $call" >&2
      false
    }
  # `\.sh +--` matches an INVOCATION and not a mention: every real call here
  # passes --image immediately, while the step's own error text ("bin/matrix.sh
  # returned no platform for ...") never does.
  done < <(grep -E 'bin/(matrix|release-tags)\.sh +--' <<<"$code")

  # AND THE FREEZE IS STILL INTACT. The flag above is safe only because every
  # tag this job asks for is immutable - bin/release-tags.sh refuses the rolling
  # forms for a deprecated version no matter what flags it is handed, but a
  # merge job that started asking for them would be relying on that refusal
  # rather than on not asking.
  [[ "$bodies" != *"kind rolling"* ]]
  [[ "$bodies" != *"kind all"* ]]
}

@test "workflows: merge.yml never re-derives a tag from defaults.debian" {
  # release-tags.sh resolves the suite as "per-version debian: override, falling
  # back to defaults.debian" (§3.1). merge.yml reconstructed the dated tag by
  # reading defaults.debian directly, so the two agree only while no version
  # carries an override - the transition mechanism the override exists for.
  #
  # COMMENTS ARE STRIPPED FIRST - whole-line AND trailing, the same two
  # expressions the smoke-matrix test above uses, for the same reason. The
  # comment that explains why the code no longer derives a suite this way has to
  # name the thing it no longer does. Without the exemption this test forbids
  # its own justification, and the way to make it pass is to delete the
  # explanation - which is the opposite of the point.
  local bodies
  bodies="$(run_bodies .github/workflows/merge.yml \
    | sed -E -e '/^[[:space:]]*#/d' -e 's/[[:space:]]+#.*$//')"
  if grep -q 'defaults\.debian' <<<"$bodies"; then
    echo "merge.yml derives a suite from defaults.debian; use bin/release-tags.sh:" >&2
    grep -n 'defaults\.debian' <<<"$bodies" >&2
    false
  fi
}

@test "workflows: merge.yml takes its platform set from config, not a literal" {
  # config/images.yml owns defaults.platforms, and bin/lib/common.sh reads and
  # validates a per-image platforms: override that bin/matrix.sh honours.
  # merge.yml hardcoded both the count (2) and the names, so a single-platform
  # image would fail the merge on an immutable-tag boundary and a third platform
  # would be published and then silently not asserted.
  local bodies
  bodies="$(run_bodies .github/workflows/merge.yml)"
  if grep -qE '(--platform +linux/|PLATFORM_COUNT)' <<<"$bodies"; then
    echo "merge.yml names a platform or a platform count literally:" >&2
    grep -nE '(--platform +linux/|PLATFORM_COUNT)' <<<"$bodies" >&2
    false
  fi
  # And it must actually ask matrix.sh instead.
  [[ "$bodies" == *"bin/matrix.sh"* ]]
}

@test "workflows: merge.yml's PLATFORM_COUNT env literal is gone" {
  run yq -r '[.jobs.merge.steps[] | select(.env.PLATFORM_COUNT != null)] | length' \
    .github/workflows/merge.yml
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "workflows: the actionlint job installs the pinned shellcheck (L5)" {
  # actionlint lints the shell inside every run: body by shelling out to
  # shellcheck, and that binary is optional: absent, the rule is skipped in
  # silence. The job installed actionlint alone, so it resolved shellcheck from
  # the runner image - either not at all, leaving six workflows' run: bodies
  # unlinted, or at whatever unpinned version GitHub ships. Both are the drift
  # this job's own comment says it exists to prevent.
  local install
  install="$(yq -r '.jobs.actions.steps[] | select(has("run")) | .run' \
    .github/workflows/lint.yml)"
  [[ "$install" == *"fetch-tools.sh"* ]]
  [[ "$install" == *"shellcheck"* ]]
  [[ "$install" == *"actionlint"* ]]
}

@test "workflows: CI and the Makefile select shell scripts the same way" {
  # The same rule as the Dockerfile-selector test above. `git ls-files '*.sh'`
  # missed tests/smoke/helpers.bash - 145 lines of ordinary bash sourced by every
  # smoke suite - so it was neither shellchecked nor shfmt-checked on either path.
  local ci mk
  ci="$(run_bodies .github/workflows/lint.yml | grep -c "git ls-files '\*.sh' '\*.bash'" || true)"
  [ "$ci" -eq 2 ]   # shellcheck and shfmt
  mk="$(grep -c "git ls-files '\*.sh' '\*.bash'" Makefile || true)"
  [ "$mk" -eq 3 ]   # lint, fmt, fmt-fix
}

@test "workflows: every job that runs steps has a timeout" {
  # smoke.yml already says why: "A hung `compose up --wait` would otherwise burn
  # the job's full six-hour default before anyone learned the pool never went
  # healthy." That argument is stronger on the release path - 36 build legs and
  # 18 merge jobs, every one doing network work, inside a concurrency group that
  # is deliberately cancel-in-progress: false.
  #
  # Jobs that only call a reusable workflow are excluded: the timeout belongs on
  # the called job, not the caller.
  local f out
  for f in .github/workflows/*.yml; do
    out="$(yq -r '.jobs | to_entries | .[]
      | select(.value.uses == null)
      | select(.value["timeout-minutes"] == null) | .key' "$f")"
    if [ -n "$out" ]; then
      echo "$f has jobs with no timeout-minutes:" >&2
      echo "$out" >&2
      false
    fi
  done
}

@test "workflows: the rebuild stamp and D43's upgrade are in ONE instruction (§9.3, D41+D43)" {
  # BOTH HALVES OR NEITHER. Busting a layer that has no upgrade in it reproduces
  # the same package set (D43's measurement: a completely cold rebuild produced
  # linux-libc-dev 6.12.100-1 again). An upgrade inside a layer that is never
  # re-executed never runs (D41). The two are only a control when they are the
  # SAME instruction, so that is what is asserted - not that both exist somewhere
  # in the file.
  local run1
  run1="$(awk '/^RUN set -eux; \\$/{f=1} f{print} f && !/\\$/{exit}' \
    images/runtime/Dockerfile | head -n 40)"
  [[ "$run1" == *'REBUILD_STAMP'* ]] || {
    echo "RUN 1 does not reference REBUILD_STAMP - the weekly rebuild cannot invalidate it" >&2
    echo "$run1" >&2
    false
  }
  [[ "$run1" == *'apt-get -y upgrade'* ]] || {
    echo "RUN 1 lost D43's upgrade - invalidation alone reproduces the same packages" >&2
    false
  }
}

@test "workflows: the rebuild stamp reaches the graph root only (§9.3)" {
  # A child declares PARENT_REF and no stamp: its cache key is chained to its
  # parent's CONTENT, so it rebuilds when runtime moves and restores from
  # type=gha when runtime did not. Passing the arg to a child would also make
  # BuildKit warn about an unused build argument on 30 of 36 legs.
  local body
  body="$(yq -r '.jobs.build.steps[] | select(.id == "args") | .run' \
    .github/workflows/build.yml)"
  [[ "$body" == *'REBUILD_STAMP'* ]]
  # The stamp must sit in the same else-branch as BASE_DIGEST - the root branch.
  local after_else
  after_else="${body##*BASE_DIGEST}"
  [[ "$after_else" == *'REBUILD_STAMP'* ]]
}

@test "workflows: the release path's cache behaviour is untouched (H3, D41)" {
  # THE OTHER HALF OF 🧭 1. The scheduled path must not buy its invalidation by
  # changing what the release path does. Both expressions must still be gated on
  # inputs.push and on NOTHING ELSE - in particular not on inputs.rebuild_stamp.
  local from to
  from="$(yq -r '.jobs.build.steps[] | select(.id == "build") | .with["cache-from"]' \
    .github/workflows/build.yml)"
  to="$(yq -r '.jobs.build.steps[] | select(.id == "build") | .with["cache-to"]' \
    .github/workflows/build.yml)"
  [ "$from" = "\${{ inputs.push && 'type=gha' || '' }}" ]
  [[ "$to" == *"inputs.push"* ]]
  [[ "$from" != *"rebuild_stamp"* ]]
  [[ "$to" != *"rebuild_stamp"* ]]
  # And no-cache must not appear at all - option (c) was rejected (D44).
  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with["no-cache"] // "absent"' \
    .github/workflows/build.yml
  [ "$output" = "absent" ]
  run yq -r '.jobs.build.steps[] | select(.id == "build") | .with["no-cache-filters"] // "absent"' \
    .github/workflows/build.yml
  [ "$output" = "absent" ]
}

@test "workflows: every build stage forwards the rebuild stamp (§9.3)" {
  # A stage that forgot it would rebuild runtime from a busted layer and then
  # build its children against a stale one - or, for build-d0, would rebuild
  # nothing at all and report success, which is THE failure mode of this
  # milestone.
  local job
  for job in build-d0 build-d1 build-d2; do
    run yq -r ".jobs.\"$job\".with.rebuild_stamp" .github/workflows/release.yml
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebuild_stamp"* ]] || {
      echo "$job does not forward inputs.rebuild_stamp" >&2
      false
    }
  done
}

@test "workflows: release.yml is callable, and only rebuild.yml sets is_rebuild" {
  run yq -r '.on | keys | join(",")' .github/workflows/release.yml
  [[ "$output" == *"workflow_call"* ]]
  # is_rebuild is a workflow_call input and NOT a workflow_dispatch one: a human
  # dispatching release.yml must not be able to claim to be a scheduled rebuild
  # and repoint :latest off a branch. There is one entry point for that, and it
  # is rebuild.yml.
  run yq -r '.on.workflow_call.inputs.is_rebuild.type' .github/workflows/release.yml
  [ "$output" = "boolean" ]
  run yq -r '.on.workflow_dispatch.inputs.is_rebuild // "absent"' .github/workflows/release.yml
  [ "$output" = "absent" ]
}

@test "workflows: the rebuild does not duplicate the release orchestration (§9.3)" {
  # The whole design. If rebuild.yml grows its own build/merge/repoint jobs
  # there are two definitions of how a LaraOCI release is assembled, and the one
  # that rots is the one no human watches every week.
  run yq -r '[.jobs | to_entries | .[] | select(.value.uses != null) | .value.uses] | join(",")' \
    .github/workflows/rebuild.yml
  [[ "$output" == *"./.github/workflows/release.yml"* ]]
  # And no job of its own may build, merge or repoint.
  run bash -c "yq -r '.jobs | to_entries | .[]
    | select([.value.steps[]? | select((.run // \"\") | test(\"imagetools create|buildx build\"))] | length > 0)
    | .key' .github/workflows/rebuild.yml"
  [ -z "$output" ]
}

@test "workflows: the rebuild declares itself a rebuild and stamps the cache (🧭 1, 🧭 2)" {
  run yq -r '.jobs.rebuild.with.is_rebuild | tostring' .github/workflows/rebuild.yml
  [ "$output" = "true" ]
  run yq -r '.jobs.rebuild.with.rebuild_stamp' .github/workflows/rebuild.yml
  [[ "$output" == *"stamp"* ]]
  # It must NEVER ask for a deprecated version (§13, trap 2).
  run yq -r '.jobs.rebuild.with.include_deprecated // "absent"' .github/workflows/rebuild.yml
  [ "$output" = "absent" ]
}

@test "workflows: exactly one job in the rebuild reads the clock (🧭 2's rule)" {
  # Same reasoning as release.yml's prepare: 36 legs must agree on one stamp. A
  # second read splits the rebuild across a midnight boundary and builds runtime's
  # two architectures against two different package sets.
  run yq -r '[.jobs | to_entries | .[]
    | select([.value.steps[]? | select((.run // "") | test("date -u"))] | length > 0)
    | .key] | join(",")' .github/workflows/rebuild.yml
  [ "$output" = "stamp" ]
}

@test "workflows: a manual rebuild cannot repoint production without saying so" {
  # THE GATE 2 FOOTGUN, in this workflow's shape. A scheduled run SHOULD repoint
  # ghcr.io/laraoci/* - that is §9.3. A HUMAN pressing "Run workflow" with the
  # namespace left blank would do the same thing by accident, on a workflow whose
  # entire purpose is to move :latest. The confirmation string is the difference
  # between the two, and it is checked in the first job, before any leg starts.
  local body
  body="$(yq -r '.jobs.guard.steps[] | select(.id == "confirm") | .run' \
    .github/workflows/rebuild.yml)"
  [[ "$body" == *"REPOINT-PRODUCTION"* ]]
  [[ "$body" == *"exit 1"* ]]
}

@test "workflows: the rebuild queues rather than cancels (§8)" {
  # Cancelling mid-publish is how a manifest list ends up missing an
  # architecture - the same reason release.yml never cancels.
  run yq -r '.concurrency."cancel-in-progress" | tostring' .github/workflows/rebuild.yml
  [ "$output" = "false" ]
}

@test "workflows: a failed rebuild reports, and reporting cannot be skipped (§9.3)" {
  # `needs: rebuild` alone would SKIP this job when the rebuild fails, which is
  # the only time it matters. always() is load-bearing, not defensive.
  run yq -r '.jobs.report.if' .github/workflows/rebuild.yml
  [[ "$output" == *"always()"* ]]
  run yq -r '.jobs.report.needs | tostring' .github/workflows/rebuild.yml
  [[ "$output" == *"rebuild"* ]]
  run yq -r '.jobs.report.permissions.issues' .github/workflows/rebuild.yml
  [ "$output" = "write" ]
}

@test "workflows: the rebuild files ONE reusable issue, not one per week (🧭 3)" {
  local body
  body="$(yq -r '.jobs.report.steps[] | select(.id == "issue") | .run' \
    .github/workflows/rebuild.yml)"
  # Found-and-updated: it must LOOK before it creates, or an unfixable CVE opens
  # 52 issues a year and the tracker stops being read.
  [[ "$body" == *"gh issue list"* ]]
  [[ "$body" == *"gh issue comment"* ]]
  [[ "$body" == *"gh issue create"* ]]
  # And the other half of "reflects current state": it closes when the scan
  # passes again.
  [[ "$body" == *"gh issue close"* ]]
}

@test "workflows: the rebuild's issue names WHICH legs failed, not just that it failed" {
  # "the rebuild failed" sends a human to the Actions tab to find out what
  # happened; an issue that names the failing legs and distinguishes a SCAN
  # failure from a BUILD failure is one they can triage from the notification.
  local body
  body="$(yq -r '.jobs.report.steps[] | select(.id == "legs") | .run' \
    .github/workflows/rebuild.yml)"
  [[ "$body" == *"actions/runs"* ]]
  [[ "$body" == *"Vulnerability gate"* ]]
}

@test "workflows: the repoint can NEVER be asked to move a deprecated rolling tag (§13)" {
  # EFFECT 2, PINNED. The version list the repoint iterates must come from
  # bin/php-versions.sh with NO flag - not from the input, not from an inline yq
  # the next person can "simplify". This is the assertion that stops a
  # half-deprecation: it fails if anyone ever plumbs include_deprecated into the
  # one job that moves :latest.
  local body
  body="$(yq -r '.jobs.repoint.steps[] | select(.id == "resolve") | .run' \
    .github/workflows/release.yml)"
  [[ "$body" == *"bin/php-versions.sh"* ]]
  [[ "$body" != *"include_deprecated"* ]]
  [[ "$body" != *"INCLUDE_DEPRECATED"* ]]
  # And the whole job, not just that step.
  run yq -r '.jobs.repoint | tostring' .github/workflows/release.yml
  [[ "$output" != *"include_deprecated"* ]]
}

@test "workflows: the scheduled rebuild's matrix never includes a deprecated version (§13)" {
  # EFFECT 1. rebuild.yml passes no include_deprecated (asserted in Task 3), and
  # the matrix step's flag comes from the input, which defaults false - so the
  # cron path cannot reach it.
  run yq -r '.on.workflow_call.inputs.include_deprecated.default | tostring' \
    .github/workflows/release.yml
  [ "$output" = "false" ]
  local body
  body="$(yq -r '.jobs.prepare.steps[] | select(.id == "legs") | .run' \
    .github/workflows/release.yml)"
  [[ "$body" == *"include-deprecated"* ]]
}
