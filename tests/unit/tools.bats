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
  for t in SHFMT YQ HADOLINT ACTIONLINT BATS CONTAINER_STRUCTURE_TEST; do
    case " $LARAOCI_TOOLS " in
      *" $t "*) : ;;
      *) echo "$t missing from LARAOCI_TOOLS" >&2; false ;;
    esac
  done
}

@test "tools: every tool is pinned by a 64-hex SHA-256" {
  local t sha_v
  for t in $LARAOCI_TOOLS; do
    sha_v="${t}_SHA256"
    if ! [[ "${!sha_v:-}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "$t has a missing or malformed SHA-256: '${!sha_v:-}'" >&2
      false
    fi
  done
}

@test "tools: every URL contains the version it claims to pin" {
  # If the URL and version disagree, the SHA guards a different artefact than
  # the one the file names - the exact substitution the hash is meant to stop.
  local t url_v ver_v
  for t in $LARAOCI_TOOLS; do
    url_v="${t}_URL"; ver_v="${t}_VERSION"
    case "${!url_v}" in
      *"${!ver_v}"*) : ;;
      *) echo "$t: URL does not contain version ${!ver_v}: ${!url_v}" >&2; false ;;
    esac
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
