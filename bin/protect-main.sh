#!/usr/bin/env bash
set -euo pipefail

# Idempotent branch-protection setup for main. Requires the four static lint
# checks plus the single pr-required aggregator (see pr-gate-job.md for why the
# matrix legs are NOT required by name). Safe to re-run; converges to the
# declared state.
#
#   ./protect-main.sh              # apply to the current repo's main
#   ./protect-main.sh --check      # print the intended payload, change nothing
#   REPO=laraoci/laraoci ./protect-main.sh
#
# Requires: gh (authenticated with admin on the repo), jq.

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
BRANCH="${BRANCH:-main}"
echo "repo: $REPO  branch: $BRANCH"

# The required check names. These must match the check names the workflows
# report EXACTLY. Static lint jobs report their `name:`; the aggregator reports
# 'pr-required'. The matrix legs are intentionally absent - they are covered
# transitively by pr-required.
REQUIRED_CHECKS=(
  "shell"          # lint.yml  job: shell       (shellcheck + shfmt)
  "actions"        # lint.yml  job: actions     (actionlint)
  "bats"           # lint.yml  job: bats        (unit tests)
  "dockerfiles"    # lint.yml  job: dockerfiles (hadolint)
  "pr-required"    # pr.yml    aggregator over the dynamic build matrix
  "smoke-required"   # smoke.yml aggregator over the dynamic PHP matrix
)

# Build the checks array for the API (strict = require branches to be up to date
# before merging; contexts carried for backward compatibility with the field).
checks_json="$(printf '%s\n' "${REQUIRED_CHECKS[@]}" \
  | jq -R '{context: .}' | jq -s '.')"

# Full protection payload. Tuned for a small maintainer team:
#  - required_status_checks.strict: PR branch must be current with main
#  - required_pull_request_reviews: 1 approval, dismiss stale on new commits
#  - enforce_admins: false (let a maintainer break glass; flip to true if you
#    want the rules to bind admins too)
#  - required_linear_history + required conversation resolution
#  - no force pushes, no deletions
payload="$(jq -n \
  --argjson checks "$checks_json" \
  '{
    required_status_checks: {
      strict: true,
      checks: $checks
    },
    enforce_admins: false,
    required_pull_request_reviews: {
      dismiss_stale_reviews: true,
      require_code_owner_reviews: true,
      required_approving_review_count: 1
    },
    required_linear_history: true,
    required_conversation_resolution: true,
    allow_force_pushes: false,
    allow_deletions: false,
    restrictions: null
  }')"

if [[ "$CHECK_ONLY" == 1 ]]; then
  echo "would PUT the following to branches/$BRANCH/protection:"
  echo "$payload" | jq .
  exit 0
fi

# The protection endpoint is a full PUT (declarative): re-running with the same
# payload is inherently idempotent - it overwrites with the identical state.
echo "$payload" \
  | gh api -X PUT "repos/$REPO/branches/$BRANCH/protection" \
      -H "Accept: application/vnd.github+json" \
      --input - > /dev/null

echo "protection applied. required checks:"
printf '  - %s\n' "${REQUIRED_CHECKS[@]}"

cat <<'NOTE'

Note: a required check name only becomes selectable/known to GitHub after it has
reported at least once. If the API rejects an unknown context, open one PR so the
checks report, then re-run this script. The names above must match the workflow
job names exactly - if you rename a job, update REQUIRED_CHECKS here (the
workflows.bats suite is a good place to assert they stay in sync).
NOTE
