# tools.env is the single pinned source for every dev/CI tool. These assertions
# generalise the bats-pinning test to all five tools and guard the invariants
# that let one file replace scattered pins without a tools Docker image:
#   - every tool pinned by a real 64-hex SHA (not just a version)
#   - every URL names the version it claims (hash guards the right artefact)
#   - no second pin file exists for any tool (one source of truth)
#   - CI and Makefile fetch through the verified path, never bare curl

setup() {
  # shellcheck source=/dev/null
  . tools.env
}

@test "tools: env declares the expected tool set" {
  [ -n "$LARAOCI_TOOLS" ]
  # Guards against a tool being dropped from iteration while its vars linger.
  # CONTAINER_STRUCTURE_TEST was absent from this list, which is why nothing
  # caught that it could not be fetched by name at all.
  for t in SHFMT YQ HADOLINT ACTIONLINT BATS CONTAINER_STRUCTURE_TEST SHELLCHECK; do
    case " $LARAOCI_TOOLS " in
      *" $t "*) : ;;
      *) echo "$t missing from LARAOCI_TOOLS" >&2; false ;;
    esac
  done
}

# A tool ships either ONE asset for every architecture (NAME_URL) or one per
# architecture (NAME_URL_AMD64 / NAME_URL_ARM64). These iterate both so a pin
# added for one architecture and forgotten for the other cannot pass.
pin_for() {
  # $1 = UPPER tool, $2 = URL|SHA256, $3 = AMD64|ARM64
  local specific="${1}_${2}_${3}" generic="${1}_${2}"
  printf '%s' "${!specific:-${!generic:-}}"
}

@test "tools: every tool is pinned by a 64-hex SHA-256 on every architecture" {
  local t arch sha
  for t in $LARAOCI_TOOLS; do
    for arch in AMD64 ARM64; do
      sha="$(pin_for "$t" SHA256 "$arch")"
      [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || {
        echo "$t/$arch has no well-formed SHA-256: '$sha'" >&2
        false
      }
    done
  done
}

@test "tools: every URL contains the version it claims to pin, on every architecture" {
  local t arch url ver_v ver
  for t in $LARAOCI_TOOLS; do
    ver_v="${t}_VERSION"
    ver="${!ver_v}"
    for arch in AMD64 ARM64; do
      url="$(pin_for "$t" URL "$arch")"
      [[ "$url" == *"$ver"* ]] || {
        echo "$t/$arch URL does not name version $ver: $url" >&2
        false
      }
    done
  done
}

@test "tools: a per-arch tool declares BOTH architectures, never one" {
  # Half a pin is the failure this catches: an arm64 URL with no arm64 SHA, or
  # an amd64-only tool that looks complete because the generic fallback happens
  # to be set. If EITHER arch-specific field exists, all four must.
  local t u_amd u_arm
  for t in $LARAOCI_TOOLS; do
    u_amd="${t}_URL_AMD64"
    u_arm="${t}_URL_ARM64"
    if [ -n "${!u_amd:-}" ] || [ -n "${!u_arm:-}" ]; then
      local s_amd="${t}_SHA256_AMD64" s_arm="${t}_SHA256_ARM64"
      [ -n "${!u_amd:-}" ] && [ -n "${!u_arm:-}" ] &&
        [ -n "${!s_amd:-}" ] && [ -n "${!s_arm:-}" ] || {
        echo "$t declares some but not all of URL/SHA256 x AMD64/ARM64" >&2
        false
      }
    fi
  done
}

@test "tools: every tool declares a known KIND" {
  local t kind_v
  for t in $LARAOCI_TOOLS; do
    kind_v="${t}_KIND"
    case "${!kind_v:-}" in
      binary | tar:*) : ;;
      *) echo "$t has unknown KIND '${!kind_v:-}'" >&2; false ;;
    esac
  done
}

@test "tools: there is no second pin file for bats" {
  # This replaces a test that compared tools.env's BATS_VERSION against
  # tests/bats.env. That file was deleted when the two fetchers merged, so the
  # `. tests/bats.env` in a subshell failed silently and the inherited
  # BATS_VERSION was compared to itself - an assertion that could not fail,
  # guarding an invariant that no longer existed.
  #
  # What IS worth guarding is that the split source does not come back.
  [ ! -e tests/bats.env ]
  [ -n "$BATS_VERSION" ]
  [ -n "$BATS_SHA256" ]
}

@test "tools: no workflow fetches a tool with bare curl (L5)" {
  # The whole point of tools.env + fetch-tools.sh is that every download is
  # verified. A raw curl in a workflow bypasses the checksum.
  local f out
  for f in .github/workflows/*.yml; do
    out="$(yq -r '.jobs[].steps[] | select(has("run")) | .run' "$f" 2>/dev/null | grep -n 'curl ' || true)"
    if [ -n "$out" ]; then
      echo "$f fetches with bare curl - route through bin/fetch-tools.sh:" >&2
      echo "$out" >&2
      false
    fi
  done
}

@test "tools: fetch-tools.sh exists, is executable, and verifies checksums" {
  [ -x bin/fetch-tools.sh ]
  run grep -c 'sha256sum -c' bin/fetch-tools.sh
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "tools: fetch-tools.sh is the ONLY fetcher (no second pinning path)" {
  # The whole point of tools.env is one fetch mechanism. A reappearing
  # fetch-tool.sh or fetch-bats.sh would be a second, separately-pinned path -
  # exactly the drift this consolidation removed.
  [ ! -e bin/fetch-tool.sh ]
  [ ! -e bin/fetch-bats.sh ]
}

@test "tools: nothing calls a removed fetcher" {
  # Catches a workflow, Makefile, or script still invoking the old names.
  run grep -rn --include=*.yml --include=*.sh --include=Makefile \
    -e 'fetch-tool\.sh' -e 'fetch-bats\.sh' \
    .github Makefile bin
  [ "$status" -eq 1 ]
}

# --- tool names vs shell variable names --------------------------------------
# A tool is named as its EXECUTABLE (`container-structure-test`), but its pins
# are shell variables, which cannot contain a hyphen. The two spellings drifted
# apart and nothing noticed: the fetcher wrote `container_structure_test` into
# the cache, bin/structure-test.sh looked for the hyphenated name on PATH and
# found an unrelated system copy, and CI's fetch of the hyphenated name exited 1
# on `CONTAINER-STRUCTURE-TEST_URL: invalid variable name`.

@test "tools: a hyphenated tool name resolves to its pinned path" {
  run bin/fetch-tools.sh --path container-structure-test
  [ "$status" -eq 0 ]
  # The path is the last line; fetch progress goes to stderr.
  [[ "${lines[-1]}" == *"/.cache/tools/bin/container-structure-test" ]]
}

@test "tools: the underscored spelling resolves to the same executable" {
  # Both spellings must name one file - two spellings resolving to two paths is
  # exactly the split that produced an unpinned local checker.
  run bin/fetch-tools.sh --path container_structure_test
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"/.cache/tools/bin/container-structure-test" ]]
}

@test "tools: a tool whose executable name differs declares it explicitly" {
  # The _BIN field, rather than a hyphen/underscore convention applied silently
  # to every tool.
  [ "$CONTAINER_STRUCTURE_TEST_BIN" = "container-structure-test" ]
}

@test "tools: no cached tool is written under an underscored alias" {
  # The stale `container_structure_test` name must not come back: a second file
  # is a second version, and whichever one a caller finds first wins.
  run bash -c "ls .cache/tools/bin 2>/dev/null | grep '_' || true"
  [ -z "$output" ]
}

@test "tools: structure-test.sh resolves the checker through the verified fetcher" {
  # Not through PATH. This is the assertion that keeps local and CI on the same
  # checker version - they were on 1.19.3 and 1.22.1 respectively.
  run grep -c 'fetch-tools.sh" --path container-structure-test' bin/structure-test.sh
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "tools: a multi-tool fetch leaves no temp files behind" {
  # The header claims one run-level temp file cleaned once on EXIT. It was one
  # mktemp per download with TMP reassigned each time, so the trap only ever saw
  # the last - a cold six-tool fetch left five tool binaries in TMPDIR.
  local tmpdir cache
  tmpdir="$(mktemp -d)"
  cache="$(mktemp -d)"
  TMPDIR="$tmpdir" LARAOCI_TOOLS_DIR="$cache" run bin/fetch-tools.sh shfmt yq
  [ "$status" -eq 0 ]
  run bash -c "ls -A '$tmpdir' | wc -l"
  [ "$output" -eq 0 ]
  rm -rf "$tmpdir" "$cache"
}

@test "tools: --list rejects an undeclared tool instead of crashing" {
  # The --list path dereferenced ${NAME}_VERSION without calling tool_declared,
  # so an unknown name died with 'NOSUCHTOOL_VERSION: unbound variable' under
  # set -u rather than the message every other path gives.
  run bin/fetch-tools.sh --list nosuchtool
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a tool declared in tools.env"* ]]
}

@test "tools: shellcheck is pinned, not taken from PATH" {
  # The one linter whose version was uncontrolled, and the one whose output
  # changes most between releases - so a local pass and a CI pass could mean
  # different things. Both callers must go through the pinned copy.
  [ -n "$SHELLCHECK_VERSION" ]
  run grep -c 'SHELLCHECK) -S warning' Makefile
  [ "$output" -ge 1 ]
  run grep -c 'fetch-tools.sh --dest .* shellcheck' .github/workflows/lint.yml
  [ "$output" -ge 1 ]
}

@test "tools: no workflow installs a TOOL through a marketplace action (L5)" {
  # The bare-curl test above reads only run: bodies, so a tool introduced with
  # `uses:` was invisible to it - which is how rhysd/actionlint@v1.7.12 sat
  # beside tools.env's 1.7.7 pin without anything noticing.
  #
  # The allowlist is actions that DO something (checkout, buildx, login, build),
  # as opposed to actions that INSTALL a tool tools.env should be pinning.
  local f out
  for f in .github/workflows/*.yml; do
    out="$(yq -r '.jobs[].steps[] | select(has("uses")) | .uses' "$f" 2>/dev/null |
      grep -vE '^(actions/checkout|docker/setup-buildx-action|docker/login-action|docker/build-push-action|actions/upload-artifact|github/codeql-action/upload-sarif)@' || true)"
    if [ -n "$out" ]; then
      echo "$f installs a tool through an action - pin it in tools.env instead:" >&2
      echo "$out" >&2
      false
    fi
  done
}

@test "tools: a cached tool with no verified stamp is re-fetched, not skipped" {
  # THE FINDING. Presence was the whole test, and five of the seven tools have a
  # runner path that does not carry the version - so `SHFMT_VERSION=9.99.9` +
  # fetch-tools.sh printed "present, skipping" and kept v3.13.1. CI (cold cache)
  # took the bump immediately and this machine never did, which is the
  # local-vs-CI drift tools.env exists to prevent.
  #
  # ASSERTS THE ABSENCE OF THE SKIP, not a successful install: the fetch that
  # follows needs the network, and what is being pinned here is that presence
  # alone no longer satisfies the fast path.
  # LARAOCI_TOOLS_DIR IS BIN_DIR ITSELF, not its parent (fetch-tools.sh:41), so
  # a KIND=binary runner lands at $cache/shfmt - the same override
  # tests/unit/tools.bats:195 already uses.
  local cache
  cache="$(mktemp -d)"
  printf '#!/bin/sh\necho v0.0.0-stale\n' >"$cache/shfmt"
  chmod +x "$cache/shfmt"

  LARAOCI_TOOLS_DIR="$cache" run bin/fetch-tools.sh shfmt
  if [[ "$output" == *"present, skipping"* ]]; then
    echo "a stale cached binary with no stamp was reported present:" >&2
    echo "$output" >&2
  fi
  [[ "$output" != *"present, skipping"* ]]
  rm -rf "$cache"
}

@test "tools: a cached tool whose stamp matches the pin is not re-fetched" {
  # The other half: the stamp must actually work as a fast path, or every make
  # target re-downloads every tool on every invocation.
  local cache arch sha
  case "$(uname -m)" in
    x86_64 | amd64) arch=AMD64 ;;
    aarch64 | arm64) arch=ARM64 ;;
    *) skip "unsupported architecture $(uname -m)" ;;
  esac
  sha="$(pin_for SHFMT SHA256 "$arch")"
  [ -n "$sha" ]

  cache="$(mktemp -d)"
  printf '#!/bin/sh\necho fake\n' >"$cache/shfmt"
  chmod +x "$cache/shfmt"
  printf '%s\n' "$sha" >"$cache/shfmt.sha256"

  LARAOCI_TOOLS_DIR="$cache" run bin/fetch-tools.sh shfmt
  [ "$status" -eq 0 ]
  [[ "$output" == *"present, skipping"* ]]
  rm -rf "$cache"
}

@test "tools: no build script resolves yq through PATH (L5)" {
  # yq is pinned in tools.env and was then taken from PATH by every consumer,
  # which is the defect bin/structure-test.sh:169 already fixed for
  # container-structure-test - after a comment explaining why PATH resolution is
  # unacceptable for a tool that decides whether an image passes. yq decides
  # more: the matrix, the build order, the uid/gid baked into the image, the
  # registry, the Debian suite, the OCI description and the size budgets.
  #
  # The bats suites are deliberately out of scope: they read repository files, so
  # a divergent yq there is a test error in front of the person running it rather
  # than a wrongly built image.
  # MATCHES COMMAND POSITION, not every occurrence of the word. The three shapes
  # a bare invocation takes in this repository are `yq …` at the start of a
  # command, `$(yq …)` / `< <(yq …)`, and `NAME=value yq …` - so the pattern is
  # "a command separator, then any run of env assignments, then yq". Anchoring it
  # that way is what keeps common.sh's own error messages ("mikefarah/yq v4",
  # "set YQ=/path/to/yq") and its `fetch-tools.sh --path yq` argument out of the
  # result: those are prose and an argument, and neither RUNS a yq off PATH.
  # Verified against the pre-fix revision - it reports all 21 real call sites.
  local f out bad=0
  for f in bin/*.sh bin/lib/*.sh tests/smoke/run.sh; do
    # Strip comments and the quoted "$YQ" form, then look for a bare invocation.
    out="$(sed -E -e 's/#.*$//' -e 's/"\$YQ"/QQ/g' "$f" |
      grep -nE '(^|[;&|(!])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*yq[[:space:]]' || true)"
    if [[ -n "$out" ]]; then
      echo "$f resolves yq through PATH:" >&2
      echo "$out" >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}
