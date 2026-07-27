# Claude Code Session - M0: Foundations

## Context

You are working on **LaraOCI**, a set of production-ready OCI images for Laravel applications. This session builds the repository foundations: the configuration file that drives everything, the scripts that turn it into a CI build matrix, and the PR pipeline that consumes them. **No image Dockerfiles are written in this session** - that is M1.

Read these before planning:

- `laraoci-spec.md` - the architecture spec. §3 (decision register), §5 (configuration file), §9.1 (development builds), §12 (repository layout) are the relevant sections.
- `laraoci-issues.md` - the issue map.

Issues in scope: **LOCI-001 through LOCI-010**.

---

## Operating rules

### 🚦 Plan before code

**Do not write any file until I have approved a plan.** Present the plan described in Gate 1 below and stop. I will respond with go-ahead or corrections.

### 🧭 Decision gates

Where you see 🧭 below, stop and ask rather than choosing. These are decisions with downstream consequences that I want to make explicitly. Present the options with your recommendation and a one-line rationale for each, then wait.

### Quality gates - non-negotiable

- `shellcheck -S warning` clean on every script in `bin/`
- `shfmt -d -i 2 -ci` clean
- `hadolint` clean on any Dockerfile (none expected this session)
- Unit tests pass locally and in CI
- Every script starts `set -euo pipefail`

### Working style

- One commit per issue, message referencing the issue number.
- No speculative generality. If the spec does not call for it, do not build it.
- If you find the spec is wrong or unimplementable, **stop and say so** rather than working around it silently. This has already happened twice on this project and both times the correction was worth more than the code.

---

## 🚦 Gate 1 - Present this plan and wait

1. **File manifest.** Every file you intend to create, with a one-line purpose. Flag anything not in spec §12.
2. **`config/images.yml` in full.** The actual proposed content, not a description. This file drives everything downstream, so I want to read it before anything consumes it.
3. **Matrix JSON shape.** A worked example of `bin/matrix.sh` output for the full matrix, plus the leg count. Show how it feeds `fromJSON()`.
4. **`bin/affected.sh` algorithm.** How you resolve changed paths to the affected image set through the `parent` graph, including how you handle deletions and renames in the changed-file list.
5. **Test plan.** What each unit test asserts.
6. **The 🧭 decisions below**, with your recommendations.

---

## Work items

### LOCI-003 - `config/images.yml`

The single source of truth (spec §5). Everything else in this session reads it.

- `defaults`: registry, user 1000:1000, workdir `/var/www/html`, `debian: trixie`, both platforms
- `php`: 8.3, 8.4, 8.5 - all `supported`, 8.4 carries `default: true`
- `extensions.core`: the twelve from §5
- `size_budgets`: placeholders, clearly commented as such - M1 replaces them with measurements
- `images` with `parent` edges: `runtime` -> `cli`/`fpm`/`builder`, `cli` -> `queue`/`scheduler`

Note in a comment that `php.<version>.debian` is a transition override, not a product axis (§3.1). It should be absent in normal operation.

### LOCI-004 - `bin/matrix.sh`

`config/images.yml` -> GitHub Actions JSON matrix.

- Skip `deprecated` versions
- Topologically sort by `parent` - build order must never be hand-maintained
- Honour per-image `platforms` overrides
- `--php`, `--image`, `--platform` filters for local use

**Trap:** there are two incompatible tools called `yq`. GitHub-hosted runners ship **mikefarah/yq** (Go), whose syntax differs from kislyuk/yq (Python wrapper around jq). Write for mikefarah, and assert the flavour at the top of the script with a clear error message rather than producing confusing failures on someone's laptop.

**Acceptance:** full matrix emits 36 legs; output is valid `fromJSON()` input. Make the leg count a test - a silent matrix collapse is the failure mode that hurts most.

### LOCI-005 - `bin/affected.sh`

Changed paths -> images requiring rebuild, walking the `parent` graph (spec §9.1).

| Change                                               | Affected   |
|------------------------------------------------------|------------|
| `images/runtime/**`                                  | all six    |
| `images/queue/**`                                    | queue only |
| `config/**`, `bin/**`, `.github/workflows/build.yml` | all six    |
| `docs/**`, `tests/structure/**`                      | none       |

**Traps:** a deleted file still implies a rebuild. A renamed file appears as two paths in some diff formats and one in others - pick a `git diff` invocation whose output shape you have verified rather than assuming.

### LOCI-006 - `bin/size-check.sh`

Implements D17. See 🧭 Decision 1 first - the measurement method determines the whole script.

- Read `size_budgets` from `config/images.yml`
- Non-zero exit on overrun, reporting the delta
- `--report` mode prints a table without failing, for PR annotation

### LOCI-007 - Reusable build workflow

`.github/workflows/build.yml`, `workflow_call` inputs: php, image, platforms, push, cache mode. Outputs image ref and digest. Buildx setup and layer cache wiring. Build args threaded from `config/images.yml`.

Verify it end-to-end against a stub Dockerfile this session - it is the foundation everything in M4 sits on.

### LOCI-008 - PR workflow

`.github/workflows/pr.yml` (spec §9.1). Matrix job runs `affected.sh` then `matrix.sh`. amd64 only, GHA layer cache, build-and-load without push. Scan advisory only. Size check in `--report` mode.

**Acceptance:** a docs-only PR builds nothing; a `runtime` PR builds all six.

### LOCI-009 - Lint and test harness

`shellcheck` and `shfmt` over `bin/`, plus the unit test harness (🧭 Decision 2). Wired as required checks.

### LOCI-001, LOCI-002, LOCI-010 - Scaffold, health files, settings

Mechanical; do these last. `SECURITY.md` should state the CVE triage posture and point at the weekly rebuild (LOCI-049) - that workflow is the actual security guarantee, so the policy should name it. `LOCI-010` produces documentation of the required settings in `CONTRIBUTING.md`, not clicking through the UI.

---

## 🧭 Decision gates

### 🧭 1 - How is image size measured?

D17 says "compressed", but that is ambiguous before a registry push exists.

- **`docker save | gzip -c | wc -c`** - works locally and on PRs with no registry, but gzips the whole tar including metadata, so it only approximates registry size.
- **Push to a local registry, sum layer sizes** - accurate, needs a registry service in CI.
- **`docker buildx imagetools inspect`** - exact, but only works post-push, so it cannot gate a PR.

This matters because PRs need the check but PRs do not push. A split (approximate on PR, exact on release) is defensible but means two code paths and two budget scales. Recommend and wait.

### 🧭 2 - Unit test framework for `bin/`

`bats` is conventional and readable but is a dependency to install; plain shell assertions have no dependency but get unreadable fast. Your call, with rationale.

### 🧭 3 - Matrix leg granularity

Does `matrix.sh` emit **one leg per (php, image, platform)**, or one leg per (php, image) carrying a platform list?

This is not cosmetic. One leg per platform is what native ARM runners need - each leg runs on its own architecture, and a separate job assembles the manifest (LOCI-041). A platform list per leg implies a single runner building both, which means QEMU emulation. The spec calls for native runners in §9.2, so I expect one leg per platform, but confirm you have thought it through and say what it implies for M4.

---

## Definition of done

- [ ] All ten issues closed with commits referencing them
- [ ] `bin/matrix.sh` emits 36 legs, asserted by a test
- [ ] `bin/affected.sh` passes tests for all four rows of the table above
- [ ] PR workflow demonstrably builds nothing for a docs-only change
- [ ] `shellcheck`, `shfmt`, and unit tests green in CI
- [ ] `config/images.yml` reviewed and merged - M1 depends entirely on its shape
