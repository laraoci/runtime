# tools.env is the single pinned source for every dev/CI tool. These assertions
# generalise the bats-pinning test to all five tools and guard the invariants
# that let one file replace scattered pins without a tools Docker image:
#   - every tool pinned by a real 64-hex SHA (not just a version)
#   - every URL names the version it claims (hash guards the right artefact)
#   - the bats pin here agrees with tests/bats.env (no split source of truth)
#   - CI and Makefile fetch through the verified path, never bare curl

setup() {
  # shellcheck source=/dev/null
  . tools.env
}

@test "tools: env declares the expected tool set" {
  [ -n "$LARAOCI_TOOLS" ]
  # Guards against a tool being dropped from iteration while its vars linger.
  for t in SHFMT YQ HADOLINT ACTIONLINT BATS; do
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

@test "tools: the bats pin agrees with tests/bats.env" {
  # bats is pinned in two files (tools.env for `make tools`, bats.env for
  # fetch-bats.sh). They must not drift - that would reintroduce the split
  # source this consolidation removes.
  local env_ver env_sha
  # shellcheck source=/dev/null
  env_ver="$(. tests/bats.env; printf '%s' "$BATS_VERSION")"
  # shellcheck source=/dev/null
  env_sha="$(. tests/bats.env; printf '%s' "$BATS_SHA256")"
  [ "$env_ver" = "$BATS_VERSION" ] || { echo "bats version differs: tools.env=$BATS_VERSION bats.env=$env_ver" >&2; false; }
  [ "$env_sha" = "$BATS_SHA256" ] || { echo "bats sha differs between tools.env and bats.env" >&2; false; }
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
