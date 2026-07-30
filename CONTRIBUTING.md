# Contributing to LaraOCI

## Working style

- **One commit per issue**, message referencing the marker, e.g.
  `feat(matrix): ... (LOCI-004)`.
- **No speculative generality.** If the spec (`docs/laraoci-Spec.md`) does not
  call for it, do not build it.
- If the spec is wrong or unimplementable, **stop and say so** rather than
  working around it silently.

## Quality gates (non-negotiable)

Run before pushing. `make hooks` prints this sequence, so you can paste it:

    make tools && make fmt && make lint && make dockerfiles && make actions && make test

Do not run the underlying tools by hand. The Makefile targets lint every tracked
shell script (`git ls-files '*.sh'`), not just `bin/`, and they use the
tools.env-pinned versions rather than whatever is on your PATH - which is what
keeps a local pass and a CI pass meaning the same thing.

Every script starts `set -euo pipefail`. `yq` means **mikefarah/yq v4** (the
scripts hard-fail on kislyuk/yq).
