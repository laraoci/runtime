# Guards that branch protection and the workflows agree. A required check name
# that no job reports deadlocks every PR ("waiting for status to be reported"),
# so the names in protect-main.sh must match real job names, and the aggregator
# the matrix hides behind must exist.

setup() {
  command -v yq >/dev/null || skip "yq required"
}

@test "protection: every required check maps to a real reporting job" {
  # Parse the ACTUAL REQUIRED_CHECKS array from the script (not a re-typed copy),
  # and confirm each name is either a lint.yml job or the pr-required aggregator
  # in pr.yml. A required name that no job reports deadlocks every PR.
  local lint_jobs pr_jobs required
  lint_jobs="$(yq -r '.jobs | keys | .[]' .github/workflows/lint.yml)"
  pr_jobs="$(yq -r '.jobs | keys | .[]' .github/workflows/pr.yml)"

  # Extract the quoted names from the REQUIRED_CHECKS=( ... ) block.
  required="$(awk '/REQUIRED_CHECKS=\(/{g=1; next} g&&/^\)/{g=0} g' bin/protect-main.sh \
    | grep -oE '"[a-z0-9-]+"' | tr -d '"')"
  [ -n "$required" ]

  for c in $required; do
    if ! grep -qx "$c" <<<"$lint_jobs" && ! grep -qx "$c" <<<"$pr_jobs"; then
      echo "required check '$c' has no reporting job in lint.yml or pr.yml" >&2
      false
    fi
  done
}

@test "protection: the pr-required aggregator exists and gates the matrix" {
  # The one check that stands in for the dynamic build matrix must exist, run
  # always(), and depend on the build job.
  run yq -r '.jobs.["pr-required"].needs | @csv' .github/workflows/pr.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *build* ]]
  run yq -r '.jobs.["pr-required"].if' .github/workflows/pr.yml
  [[ "$output" == *always* ]]
}

@test "protection: no per-leg matrix name is hardcoded as required" {
  # protect-main.sh must NOT list a matrix-leg-shaped context; those names are
  # volatile and absent on docs-only PRs. This catches a well-meaning edit that
  # re-adds 'build (...)' to the required list.
  run grep -nE '"(build|pr) \(' bin/protect-main.sh
  [ "$status" -ne 0 ]
}

@test "protection: script requires strict (up-to-date) status checks" {
  grep -q 'strict: true' bin/protect-main.sh
}
