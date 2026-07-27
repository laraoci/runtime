# Contributing to LaraOCI

## Working style

- **One commit per issue**, message referencing the marker, e.g.
  `feat(matrix): ... (LOCI-004)`.
- **No speculative generality.** If the spec (`docs/laraoci-Spec.md`) does not
  call for it, do not build it.
- If the spec is wrong or unimplementable, **stop and say so** rather than
  working around it silently.

## Quality gates (non-negotiable)

Run before pushing:

    shellcheck -S warning bin/*.sh bin/lib/*.sh
    shfmt -d -i 2 -ci bin
    tests/bats/bin/bats tests/unit
    actionlint .github/workflows/*.yml
    hadolint <any Dockerfile>

Every script starts `set -euo pipefail`. `yq` means **mikefarah/yq v4** (the
scripts hard-fail on kislyuk/yq).
