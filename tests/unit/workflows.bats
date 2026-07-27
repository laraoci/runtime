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
