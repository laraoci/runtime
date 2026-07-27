## Summary

<!-- What changes, and why. Reference the issue: LOCI-NNN. -->

## Checklist

- [ ] `shellcheck -S warning` and `shfmt -d -i 2 -ci` clean
- [ ] `tests/bats/bin/bats tests/unit` green
- [ ] `actionlint` clean on any workflow changes
- [ ] One commit per issue, message references `LOCI-NNN`
- [ ] No speculative generality - only what the spec calls for
