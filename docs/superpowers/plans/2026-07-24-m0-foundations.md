# M0 - Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the LaraOCI repository foundations - the `config/images.yml` source of truth, the shell scripts that turn it into a CI build matrix and an affected-image set, the size-budget checker, and the PR/reusable build pipeline that consumes them. No image Dockerfiles are written here (that is M1).

**Architecture:** `config/images.yml` is the single source of truth (spec §5). `bin/matrix.sh` reads it and emits a GitHub Actions JSON matrix (one leg per php × image × platform). `bin/affected.sh` maps changed paths to the set of images needing rebuild by walking the `parent` graph. `bin/size-check.sh` enforces per-image size budgets (D17). A reusable `build.yml` workflow (`workflow_call`) builds one leg; `pr.yml` fans out affected legs, amd64-only, build-and-load without push. All three scripts share `bin/lib/common.sh` for config resolution and a mikefarah/yq guard.

**Tech Stack:** Bash (`set -euo pipefail`), mikefarah/yq v4 (Go), `jq`, `bats-core` for unit tests, `shellcheck` + `shfmt` + `actionlint` for linting, GitHub Actions with `docker/build-push-action` + Buildx.

## Resolved decisions (the three 🧭 gates from `docs/m0-foundations.md`)

- **🧭 1 - Size measurement:** `docker save <ref> | gzip -c | wc -c`. Single code path, works locally and on PRs with no registry (the PR gate is the whole point of D17). Approximate vs registry size; documented as such in the script. Exact `imagetools inspect` measurement is deferred to M4 when push exists. The §5 budgets are placeholders that M1 re-freezes against this exact tool, so the unit only has to be *consistent*, not canonical.
- **🧭 2 - Test framework:** `bats-core`, pinned as a git submodule at `tests/bats`. `shellcheck`/`shfmt` are already required deps, so "zero-dependency plain shell" buys little, and the marquee 36-leg assertion benefits from bats reporting *what* the count was on failure.
- **🧭 3 - Leg granularity:** one leg per `(php, image, platform)` -> 3 × 6 × 2 = **36 legs**, matching spec §5. Each leg runs on its own native runner (§9.2); no QEMU. **Implication for M4:** each build leg produces a single-arch image + digest, and LOCI-041 adds a separate manifest-assembly job that fans those digests into a multi-arch manifest list. The PR workflow collapses to amd64 only, then `affected.sh` prunes further.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from the spec.

- **Every script starts** `set -euo pipefail` (sourced libraries excepted - they inherit it from the caller).
- **`shellcheck -S warning`** clean on every script in `bin/` (including `bin/lib/`).
- **`shfmt -d -i 2 -ci`** clean on every shell script (2-space indent, switch-case indented).
- **`hadolint`** clean on any Dockerfile (only the `tests/stub/Dockerfile` this session).
- **`actionlint`** clean on every workflow in `.github/workflows/`.
- **Unit tests** (`bats`) pass locally and in CI.
- **One commit per issue**, message referencing the issue marker, e.g. `feat(matrix): ... (LOCI-004)`.
- **No speculative generality.** If the spec does not call for it, do not build it.
- **`yq` means mikefarah/yq v4** (Go). The scripts hard-fail on kislyuk/yq (the Python jq wrapper).
- **Registry:** `ghcr.io/laraoci`. **User/UID/GID:** `laravel` / `1000` / `1000`. **Workdir:** `/var/www/html`. **Debian:** `trixie`. **Platforms:** `linux/amd64`, `linux/arm64`.
- **PHP:** `8.3`, `8.4`, `8.5` - all `supported`; `8.4` carries `default: true`.
- **Full matrix = 36 legs.** A silent matrix collapse is the worst failure mode; it is an asserted test.

## File manifest (flag anything not in spec §12)

| File                                                                                                    | Purpose                                               | In §12?                                   |
|---------------------------------------------------------------------------------------------------------|-------------------------------------------------------|-------------------------------------------|
| `config/images.yml`                                                                                     | Single source of truth (LOCI-003)                     | yes                                       |
| `bin/lib/common.sh`                                                                                     | Shared: `CONFIG` resolution + mikefarah/yq guard      | new helper (under `bin/`, §12-consistent) |
| `bin/matrix.sh`                                                                                         | `images.yml` -> GHA JSON matrix (LOCI-004)            | yes                                       |
| `bin/affected.sh`                                                                                       | Changed paths -> affected image set (LOCI-005)        | yes                                       |
| `bin/size-check.sh`                                                                                     | D17 budget enforcement (LOCI-006)                     | yes                                       |
| `tests/bats/`                                                                                           | bats-core, git submodule (test harness)               | under `tests/`                            |
| `tests/unit/*.bats`                                                                                     | Unit tests for the three scripts                      | under `tests/`                            |
| `tests/fixtures/*.yml`                                                                                  | Config fixtures for deprecation/override tests        | under `tests/`                            |
| `tests/stub/Dockerfile`                                                                                 | Trivial image to verify the build pipeline end-to-end | under `tests/`                            |
| `.github/workflows/lint.yml`                                                                            | shellcheck + shfmt + actionlint + bats (LOCI-009)     | `.github/workflows/`                      |
| `.github/workflows/build.yml`                                                                           | Reusable single-leg build (LOCI-007)                  | yes                                       |
| `.github/workflows/pr.yml`                                                                              | PR pipeline: affected -> matrix -> build (LOCI-008)   | yes                                       |
| `.editorconfig`, `.gitignore`                                                                           | Repo hygiene (LOCI-009/001 bootstrap)                 | consistent                                |
| `README.md`, `LICENSE`                                                                                  | Scaffold (LOCI-001)                                   | `docs`/root                               |
| `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/*.yml`, `CODE_OF_CONDUCT.md`, `SECURITY.md` | Community health (LOCI-002)                           | `.github/`                                |
| `CONTRIBUTING.md`                                                                                       | Required-settings documentation (LOCI-010)            | root                                      |

**Task ordering note:** the M0 doc says "do scaffold/health/settings last." This plan honours that - the *prose* documentation (README, LICENSE, health files, CONTRIBUTING) is Tasks 8-10. But git init, `.gitignore`, the bats submodule, and lint config are tooling that TDD and the "one commit per issue" rule require *first*, so they are folded into Task 1 (LOCI-009). This is the skill's "fold setup into the task whose deliverable needs it."

---

## Task 1: Bootstrap - git, harness, lint CI (LOCI-009)

**Files:**
- Create: `.gitignore`, `.editorconfig`
- Create: `tests/bats/` (git submodule)
- Create: `.github/workflows/lint.yml`
- Create: `tests/unit/.gitkeep`

**Interfaces:**
- Produces: a git repo with `bats` runnable via `tests/bats/bin/bats tests/unit`, and a lint workflow running `shellcheck -S warning`, `shfmt -d -i 2 -ci`, `actionlint`, and `bats`.

- [ ] **Step 1: Initialise the repository**

Run:
```bash
cd /home/ntoufoudis/Sites/laraoci/runtime
git init
git config core.autocrlf false
```
Expected: `Initialized empty Git repository`.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
# LaraOCI
*.log
.DS_Store
/tmp/
/.idea/
```

- [ ] **Step 3: Write `.editorconfig`**

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.sh]
indent_style = space
indent_size = 2

[*.{yml,yaml}]
indent_style = space
indent_size = 2
```

- [ ] **Step 4: Add bats-core as a pinned submodule**

Run:
```bash
git submodule add https://github.com/bats-core/bats-core tests/bats
git -C tests/bats checkout v1.11.0
git add tests/bats .gitmodules
mkdir -p tests/unit && touch tests/unit/.gitkeep
```
Expected: `tests/bats` populated; `tests/bats/bin/bats --version` prints `Bats 1.11.0`.

- [ ] **Step 5: Verify the harness runs (empty suite)**

Run: `tests/bats/bin/bats tests/unit || true`
Expected: bats reports `1..0` (no `.bats` files yet) and exits 0. This proves the runner works before any test exists.

- [ ] **Step 6: Write `.github/workflows/lint.yml`**

```yaml
name: lint

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  shell:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - name: Install tools
        run: |
          sudo apt-get update
          sudo apt-get install -y shellcheck
          curl -fsSL https://github.com/mvdan/sh/releases/download/v3.8.0/shfmt_v3.8.0_linux_amd64 \
            -o /usr/local/bin/shfmt && sudo chmod +x /usr/local/bin/shfmt
      - name: shellcheck
        run: shellcheck -S warning bin/*.sh bin/lib/*.sh
      - name: shfmt
        run: shfmt -d -i 2 -ci bin

  actions:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/actionlint@v1.7.1

  bats:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - name: Install yq (mikefarah) and jq
        run: |
          sudo curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
            -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
          sudo apt-get update && sudo apt-get install -y jq
      - name: Run unit tests
        run: tests/bats/bin/bats tests/unit
```

- [ ] **Step 7: Lint the workflow itself**

Run: `actionlint .github/workflows/lint.yml` (or skip locally if `actionlint` is not installed; CI covers it)
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add .gitignore .editorconfig .gitmodules tests/bats tests/unit/.gitkeep .github/workflows/lint.yml
git commit -m "chore: bootstrap repo, bats harness, and lint CI (LOCI-009)"
```

---

## Task 2: `config/images.yml` (LOCI-003)

**Files:**
- Create: `config/images.yml`
- Test: `tests/unit/config.bats`

**Interfaces:**
- Produces: `config/images.yml` with keys `version`, `defaults`, `php`, `extensions`, `size_budgets`, `images`. Consumed by every script via `CONFIG` (default `config/images.yml`).

- [ ] **Step 1: Write the failing test**

`tests/unit/config.bats`:
```bash
setup() {
  YQ() { yq "$@" config/images.yml; }
}

@test "config: exactly six images with parent edges" {
  run bash -c "yq -r '.images | keys | length' config/images.yml"
  [ "$status" -eq 0 ]
  [ "$output" -eq 6 ]
}

@test "config: exactly one php version is default" {
  run bash -c "yq -r '[.php[] | select(.default == true)] | length' config/images.yml"
  [ "$output" -eq 1 ]
}

@test "config: default php version is 8.4" {
  run bash -c "yq -r '.php | to_entries | map(select(.value.default == true))[0].key' config/images.yml"
  [ "$output" = "8.4" ]
}

@test "config: parent edges match the catalog (D1)" {
  run bash -c "yq -r '.images.fpm.parent' config/images.yml"
  [ "$output" = "runtime" ]
  run bash -c "yq -r '.images.queue.parent' config/images.yml"
  [ "$output" = "cli" ]
  run bash -c "yq -r '.images.scheduler.parent' config/images.yml"
  [ "$output" = "cli" ]
}

@test "config: twelve core extensions" {
  run bash -c "yq -r '.extensions.core | length' config/images.yml"
  [ "$output" -eq 12 ]
}

@test "config: every image has a size budget" {
  run bash -c "yq -r '.images | keys - (.size_budgets | keys) | length' config/images.yml"
  [ "$output" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/config.bats`
Expected: FAIL - `config/images.yml` does not exist yet.

- [ ] **Step 3: Write `config/images.yml`**

```yaml
version: 1

defaults:
  registry: ghcr.io/laraoci
  user:
    name: laravel
    uid: 1000
    gid: 1000
  workdir: /var/www/html
  debian: trixie
  platforms:
    - linux/amd64
    - linux/arm64

php:
  # Exactly one version carries `default: true`; it backs :latest (spec §5).
  # `status` is `supported` | `deprecated`; only `supported` is built.
  # A per-version `debian:` key here would OVERRIDE defaults.debian - it is the
  # trixie-transition mechanism of §3.1, NOT a product axis. Absent in normal
  # operation; present only while migrating a single version off an ageing OS.
  "8.3":
    status: supported
  "8.4":
    status: supported
    default: true
  "8.5":
    status: supported

extensions:
  # The twelve-extension core set (spec §5). Uniform across all three PHP
  # versions - install-php-extensions supports every one on 5.5-8.5 (§7.1).
  core:
    - bcmath
    - exif
    - gd
    - imagick
    - intl
    - opcache
    - pcntl
    - pdo_mysql
    - pdo_pgsql
    - redis
    - sockets
    - zip

size_budgets:
  # PLACEHOLDERS, compressed MB. These are provisional guesses, NOT measured
  # values. M1 (LOCI-021) measures real sizes on all three PHP versions and
  # replaces every number here, then D17 freezes them. CI fails on overrun.
  runtime: 220
  cli: 225
  fpm: 235
  builder: 500
  queue: 225
  scheduler: 225

images:
  # `parent` defines build order; CI topologically sorts (no hand-maintained
  # ordering). The graph is single-rooted at `runtime` (D1/D2/D18):
  #   runtime -> cli, fpm, builder ;  cli -> queue, scheduler
  runtime:
    dockerfile: images/runtime/Dockerfile
  cli:
    parent: runtime
    dockerfile: images/cli/Dockerfile
  fpm:
    parent: runtime
    dockerfile: images/fpm/Dockerfile
    exposes: [9000]
  builder:
    parent: runtime
    dockerfile: images/builder/Dockerfile
  queue:
    parent: cli
    dockerfile: images/queue/Dockerfile
  scheduler:
    parent: cli
    dockerfile: images/scheduler/Dockerfile
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `tests/bats/bin/bats tests/unit/config.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add config/images.yml tests/unit/config.bats
git commit -m "feat(config): images.yml source of truth with parent graph and budgets (LOCI-003)"
```

---

## Task 3: `bin/matrix.sh` + shared `bin/lib/common.sh` (LOCI-004)

**Files:**
- Create: `bin/lib/common.sh`
- Create: `bin/matrix.sh`
- Test: `tests/unit/matrix.bats`
- Test: `tests/fixtures/deprecated.yml`, `tests/fixtures/platform-override.yml`

**Interfaces:**
- Consumes: `config/images.yml` (via `CONFIG`).
- Produces:
  - `bin/lib/common.sh` exposing `require_mikefarah_yq` and setting `: "${CONFIG:=config/images.yml}"`. Sourced by `matrix.sh`, `affected.sh`, `size-check.sh`.
  - `bin/matrix.sh` printing a single-line JSON object `{"include":[{"php":..,"image":..,"platform":..}, ...]}` suitable for `fromJSON()`. Flags: `--php <v>`, `--image <name>`, `--platform <p>`. Full matrix = 36 legs. Images emitted in topological (`parent`-first) order; `deprecated` php versions skipped; per-image `platforms` override honoured over `defaults.platforms`.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/deprecated.yml` (8.5 deprecated -> expect 24 legs, no 8.5):
```yaml
version: 1
defaults:
  registry: ghcr.io/laraoci
  platforms: [linux/amd64, linux/arm64]
php:
  "8.3": { status: supported }
  "8.4": { status: supported, default: true }
  "8.5": { status: deprecated }
size_budgets: { runtime: 1, cli: 1, fpm: 1, builder: 1, queue: 1, scheduler: 1 }
images:
  runtime: {}
  cli: { parent: runtime }
  fpm: { parent: runtime }
  builder: { parent: runtime }
  queue: { parent: cli }
  scheduler: { parent: cli }
```

`tests/fixtures/platform-override.yml` (builder amd64-only -> expect 33 legs):
```yaml
version: 1
defaults:
  registry: ghcr.io/laraoci
  platforms: [linux/amd64, linux/arm64]
php:
  "8.3": { status: supported }
  "8.4": { status: supported, default: true }
  "8.5": { status: supported }
size_budgets: { runtime: 1, cli: 1, fpm: 1, builder: 1, queue: 1, scheduler: 1 }
images:
  runtime: {}
  cli: { parent: runtime }
  fpm: { parent: runtime }
  builder: { parent: runtime, platforms: [linux/amd64] }
  queue: { parent: cli }
  scheduler: { parent: cli }
```

- [ ] **Step 2: Write the failing test**

`tests/unit/matrix.bats`:
```bash
setup() {
  PATH="$PWD/bin:$PATH"
}

@test "matrix: full matrix emits exactly 36 legs" {
  run bash -c "bin/matrix.sh | jq '.include | length'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 36 ]
}

@test "matrix: output is a valid object with an include array" {
  run bash -c "bin/matrix.sh | jq -e '.include | type == \"array\"'"
  [ "$status" -eq 0 ]
}

@test "matrix: every leg has php, image, platform" {
  run bash -c "bin/matrix.sh | jq -e '.include | all(has(\"php\") and has(\"image\") and has(\"platform\"))'"
  [ "$status" -eq 0 ]
}

@test "matrix: runtime is ordered before its children (topological)" {
  first_runtime=$(bin/matrix.sh | jq -r '[.include[].image] | index("runtime")')
  first_cli=$(bin/matrix.sh | jq -r '[.include[].image] | index("cli")')
  first_queue=$(bin/matrix.sh | jq -r '[.include[].image] | index("queue")')
  [ "$first_runtime" -lt "$first_cli" ]
  [ "$first_cli" -lt "$first_queue" ]
}

@test "matrix: deprecated php versions are skipped" {
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/matrix.sh | jq '.include | length'"
  [ "$output" -eq 24 ]
  run bash -c "CONFIG=tests/fixtures/deprecated.yml bin/matrix.sh | jq -e '[.include[].php] | index(\"8.5\") == null'"
  [ "$status" -eq 0 ]
}

@test "matrix: per-image platform override is honoured" {
  run bash -c "CONFIG=tests/fixtures/platform-override.yml bin/matrix.sh | jq '.include | length'"
  [ "$output" -eq 33 ]
  run bash -c "CONFIG=tests/fixtures/platform-override.yml bin/matrix.sh | jq -e '[.include[] | select(.image==\"builder\") | .platform] | unique == [\"linux/amd64\"]'"
  [ "$status" -eq 0 ]
}

@test "matrix: --php filter narrows to one version" {
  run bash -c "bin/matrix.sh --php 8.4 | jq -e '[.include[].php] | unique == [\"8.4\"]'"
  [ "$status" -eq 0 ]
  run bash -c "bin/matrix.sh --php 8.4 | jq '.include | length'"
  [ "$output" -eq 12 ]
}

@test "matrix: --image and --platform filters compose" {
  run bash -c "bin/matrix.sh --image runtime --platform linux/amd64 | jq '.include | length'"
  [ "$output" -eq 3 ]
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/matrix.bats`
Expected: FAIL - `bin/matrix.sh` does not exist.

- [ ] **Step 4: Write `bin/lib/common.sh`**

```bash
#!/usr/bin/env bash
# Sourced by bin/matrix.sh, bin/affected.sh, bin/size-check.sh.
# Not executed directly; inherits `set -euo pipefail` from the caller.

# CONFIG can be overridden (used by tests with fixtures); defaults to the
# single source of truth.
: "${CONFIG:=config/images.yml}"

# Fail loudly if the wrong `yq` is on PATH. GitHub-hosted runners ship
# mikefarah/yq (Go); kislyuk/yq is a Python wrapper around jq with an
# incompatible syntax. Assert the flavour rather than producing confusing
# downstream failures.
require_mikefarah_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "error: 'yq' not found. Install mikefarah/yq v4: https://github.com/mikefarah/yq" >&2
    exit 1
  fi
  if ! yq --version 2>&1 | grep -qi mikefarah; then
    echo "error: wrong 'yq' on PATH. This project requires mikefarah/yq v4 (Go)," >&2
    echo "       not kislyuk/yq (the Python jq wrapper); their syntaxes differ." >&2
    echo "       found: $(yq --version 2>&1)" >&2
    exit 1
  fi
}
```

- [ ] **Step 5: Write `bin/matrix.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

php_filter=""
image_filter=""
platform_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php) php_filter="$2"; shift 2 ;;
    --image) image_filter="$2"; shift 2 ;;
    --platform) platform_filter="$2"; shift 2 ;;
    -h | --help)
      echo "usage: matrix.sh [--php V] [--image NAME] [--platform P]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# Supported (non-deprecated) PHP versions, in file order.
mapfile -t php_versions < <(
  yq -r '.php | to_entries | .[] | select(.value.status != "deprecated") | .key' "$CONFIG"
)

# Image names and their parents.
mapfile -t image_names < <(yq -r '.images | keys | .[]' "$CONFIG")
declare -A parent=()
for img in "${image_names[@]}"; do
  parent["$img"]="$(yq -r ".images.\"$img\".parent // \"\"" "$CONFIG")"
done

# Topological sort by parent (Kahn-style): emit an image once its parent has
# been emitted. Build order must never be hand-maintained.
sorted=()
declare -A emitted=()
while ((${#sorted[@]} < ${#image_names[@]})); do
  progress=0
  for img in "${image_names[@]}"; do
    [[ -n "${emitted[$img]:-}" ]] && continue
    p="${parent[$img]}"
    if [[ -z "$p" || -n "${emitted[$p]:-}" ]]; then
      sorted+=("$img")
      emitted["$img"]=1
      progress=1
    fi
  done
  ((progress)) || {
    echo "error: cycle or dangling parent in images graph" >&2
    exit 1
  }
done

legs=()
for php in "${php_versions[@]}"; do
  [[ -n "$php_filter" && "$php" != "$php_filter" ]] && continue
  for img in "${sorted[@]}"; do
    [[ -n "$image_filter" && "$img" != "$image_filter" ]] && continue
    mapfile -t platforms < <(
      yq -r ".images.\"$img\".platforms // .defaults.platforms | .[]" "$CONFIG"
    )
    for plat in "${platforms[@]}"; do
      [[ -n "$platform_filter" && "$plat" != "$platform_filter" ]] && continue
      legs+=("$(jq -nc \
        --arg php "$php" --arg image "$img" --arg platform "$plat" \
        '{php: $php, image: $image, platform: $platform}')")
    done
  done
done

if ((${#legs[@]} == 0)); then
  echo '{"include":[]}'
  exit 0
fi

printf '%s\n' "${legs[@]}" | jq -sc '{include: .}'
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `tests/bats/bin/bats tests/unit/matrix.bats`
Expected: PASS (8 tests). Also, spot-check the shape feeds `fromJSON()`:

Run: `bin/matrix.sh --image runtime --platform linux/amd64`
Expected: `{"include":[{"php":"8.3","image":"runtime","platform":"linux/amd64"},{"php":"8.4",...},{"php":"8.5",...}]}` - consumed downstream as `strategy: { matrix: ${{ fromJSON(needs.matrix.outputs.legs) }} }`.

- [ ] **Step 7: Lint**

Run: `shellcheck -S warning bin/matrix.sh bin/lib/common.sh && shfmt -d -i 2 -ci bin`
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add bin/lib/common.sh bin/matrix.sh tests/unit/matrix.bats tests/fixtures/deprecated.yml tests/fixtures/platform-override.yml
git commit -m "feat(matrix): images.yml to GHA JSON matrix, 36-leg count asserted (LOCI-004)"
```

---

## Task 4: `bin/affected.sh` (LOCI-005)

**Files:**
- Create: `bin/affected.sh`
- Test: `tests/unit/affected.bats`

**Interfaces:**
- Consumes: `config/images.yml` (parent graph via `CONFIG`); `bin/lib/common.sh`.
- Produces: `bin/affected.sh` reading changed paths from **stdin** (one per line), or computing them from git when `--base <ref>` is given. Emits the affected image set (in config order), newline-separated by default or as a JSON array with `--json`. Mapping rules (spec §9.1 + M0 doc table):

  | Changed path                                         | Affected                         |
  |------------------------------------------------------|----------------------------------|
  | `images/<name>/**`                                   | `<name>` and all its descendants |
  | `config/**`, `bin/**`, `.github/workflows/build.yml` | all six                          |
  | `docs/**`, `tests/**`                                | none                             |
  | anything else                                        | all six (conservative)           |

  Deletions and both halves of renames map to the same image and still trigger a rebuild - the git invocation is `git diff --no-renames --name-only <base>`, whose output shape is verified (renames split into delete-old + add-new, deletions present).

- [ ] **Step 1: Write the failing test**

`tests/unit/affected.bats`:
```bash
affected() { printf '%s\n' "$@" | bin/affected.sh; }

@test "affected: images/runtime change rebuilds all six" {
  run affected "images/runtime/Dockerfile"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "builder cli fpm queue runtime scheduler " ]
}

@test "affected: images/queue change rebuilds queue only" {
  run affected "images/queue/Dockerfile"
  [ "$output" = "queue" ]
}

@test "affected: images/cli change rebuilds cli and its descendants" {
  run affected "images/cli/Dockerfile"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "cli queue scheduler " ]
}

@test "affected: config change rebuilds all six" {
  run affected "config/images.yml"
  [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "affected: bin change rebuilds all six" {
  run affected "bin/matrix.sh"
  [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "affected: build workflow change rebuilds all six" {
  run affected ".github/workflows/build.yml"
  [ "$(echo "$output" | wc -l)" -eq 6 ]
}

@test "affected: docs-only change rebuilds nothing" {
  run affected "docs/readme.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "affected: tests/structure change rebuilds nothing" {
  run affected "tests/structure/runtime.yaml"
  [ -z "$output" ]
}

@test "affected: a deleted image file still triggers a rebuild" {
  # affected.sh works from a path list; a deletion is just a path, so the
  # queue rebuild fires exactly as for a modification.
  run affected "images/queue/Dockerfile"
  [ "$output" = "queue" ]
}

@test "affected: multiple paths union their image sets" {
  run affected "images/queue/Dockerfile" "images/scheduler/Dockerfile"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "queue scheduler " ]
}

@test "affected: --json emits a JSON array" {
  run bash -c "printf '%s\n' images/queue/Dockerfile | bin/affected.sh --json"
  [ "$output" = '["queue"]' ]
}

@test "affected: --json on nothing emits []" {
  run bash -c "printf '%s\n' docs/x.md | bin/affected.sh --json"
  [ "$output" = "[]" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/affected.bats`
Expected: FAIL - `bin/affected.sh` does not exist.

- [ ] **Step 3: Write `bin/affected.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

base=""
as_json=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --json) as_json=1; shift ;;
    -h | --help)
      echo "usage: affected.sh [--base REF] [--json]   (paths on stdin if --base absent)" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# Changed paths: from git (rename detection OFF so a rename splits into
# delete-old + add-new, both mapping to the same image; deletions included),
# or from stdin.
changed=()
if [[ -n "$base" ]]; then
  mapfile -t changed < <(git diff --no-renames --name-only "$base")
else
  mapfile -t changed
fi

# Image names and the parent->children adjacency.
mapfile -t image_names < <(yq -r '.images | keys | .[]' "$CONFIG")
declare -A children=()
for img in "${image_names[@]}"; do children["$img"]=""; done
for img in "${image_names[@]}"; do
  p="$(yq -r ".images.\"$img\".parent // \"\"" "$CONFIG")"
  [[ -n "$p" ]] && children["$p"]+="$img "
done

declare -A affected=()

add_all() {
  for i in "${image_names[@]}"; do affected["$i"]=1; done
}

# BFS over descendants: the image itself plus everything that inherits from it.
add_with_descendants() {
  local -a queue=("$1")
  while ((${#queue[@]})); do
    local cur="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${affected[$cur]:-}" ]] && continue
    affected["$cur"]=1
    local c
    for c in ${children[$cur]}; do queue+=("$c"); done
  done
}

for path in "${changed[@]}"; do
  [[ -z "$path" ]] && continue
  case "$path" in
    docs/* | tests/*) : ;; # documentation and tests never rebuild an image
    config/* | bin/* | .github/workflows/build.yml) add_all ;;
    images/*/*)
      name="${path#images/}"
      name="${name%%/*}"
      if [[ -n "${children[$name]+set}" ]]; then
        add_with_descendants "$name"
      else
        add_all # unknown image directory - be conservative
      fi
      ;;
    *) add_all ;; # unrecognised path - rebuild everything rather than miss one
  esac
done

result=()
for img in "${image_names[@]}"; do
  [[ -n "${affected[$img]:-}" ]] && result+=("$img")
done

if ((as_json)); then
  if ((${#result[@]} == 0)); then
    echo '[]'
  else
    printf '%s\n' "${result[@]}" | jq -R . | jq -sc .
  fi
  exit 0
fi

((${#result[@]})) && printf '%s\n' "${result[@]}"
exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/bats/bin/bats tests/unit/affected.bats`
Expected: PASS (12 tests).

- [ ] **Step 5: Verify the git invocation shape (manual, one-time)**

Run:
```bash
git checkout -b _shape-check
git rm config/images.yml >/dev/null && git mv bin/matrix.sh bin/matrix2.sh 2>/dev/null || true
git diff --no-renames --name-only HEAD
git checkout -- . 2>/dev/null; git checkout main; git branch -D _shape-check
```
Expected: the deleted `config/images.yml` appears in the list, and a rename shows as two paths. This confirms `--no-renames --name-only` is the invocation whose output shape we rely on. (Skip if it disrupts the working tree; the stdin-driven tests already cover the mapping logic.)

- [ ] **Step 6: Lint**

Run: `shellcheck -S warning bin/affected.sh && shfmt -d -i 2 -ci bin`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add bin/affected.sh tests/unit/affected.bats
git commit -m "feat(affected): changed paths to affected images via parent graph (LOCI-005)"
```

---

## Task 5: `bin/size-check.sh` (LOCI-006)

**Files:**
- Create: `bin/size-check.sh`
- Test: `tests/unit/size-check.bats`

**Interfaces:**
- Consumes: `config/images.yml` (`size_budgets`, `defaults.registry` via `CONFIG`); `bin/lib/common.sh`.
- Produces: `bin/size-check.sh`. Flags: `--report` (print the table, always exit 0), `--image <name>` (limit to one image). Measures compressed size via `docker save <ref> | gzip -c | wc -c`, overridable for tests with env `LARAOCI_MEASURE_CMD` (a bash snippet receiving the ref as `$1`, echoing bytes). Budget unit is **MB = 1,000,000 bytes** (documented; M1 re-freezes against this exact tool, so consistency is what matters). Exits non-zero if any checked image exceeds its budget, printing the per-image delta.

- [ ] **Step 1: Write the failing test**

`tests/unit/size-check.bats`:
```bash
# LARAOCI_MEASURE_CMD receives the ref as $1 and echoes a byte count.
# Branch on the image name embedded in the ref.
setup() {
  export CONFIG=tests/fixtures/budgets.yml
}

@test "size-check: passes when every image is under budget" {
  export LARAOCI_MEASURE_CMD='echo 50000000'   # 50 MB, under all budgets
  run bin/size-check.sh
  [ "$status" -eq 0 ]
}

@test "size-check: fails non-zero when an image is over budget" {
  export LARAOCI_MEASURE_CMD='case "$1" in *runtime*) echo 900000000;; *) echo 10000000;; esac'
  run bin/size-check.sh
  [ "$status" -ne 0 ]
}

@test "size-check: reports the delta for an overrun" {
  export LARAOCI_MEASURE_CMD='case "$1" in *runtime*) echo 250000000;; *) echo 10000000;; esac'
  run bin/size-check.sh --image runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *"OVER"* ]]
  [[ "$output" == *"runtime"* ]]
}

@test "size-check: --report never fails even on overrun" {
  export LARAOCI_MEASURE_CMD='echo 900000000'   # over every budget
  run bin/size-check.sh --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"OVER"* ]]
}

@test "size-check: --image limits the check to one image" {
  export LARAOCI_MEASURE_CMD='echo 10000000'
  run bin/size-check.sh --image cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"cli"* ]]
  [[ "$output" != *"builder"* ]]
}
```

`tests/fixtures/budgets.yml`:
```yaml
version: 1
defaults:
  registry: ghcr.io/laraoci
size_budgets:
  runtime: 220
  cli: 225
  fpm: 235
  builder: 500
  queue: 225
  scheduler: 225
images:
  runtime: {}
  cli: { parent: runtime }
  fpm: { parent: runtime }
  builder: { parent: runtime }
  queue: { parent: cli }
  scheduler: { parent: cli }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/size-check.bats`
Expected: FAIL - `bin/size-check.sh` does not exist.

- [ ] **Step 3: Write `bin/size-check.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_mikefarah_yq

# Budget unit. The spec (§5/D17) states "compressed, MB". We treat MB as
# 1,000,000 bytes. The measurement (docker save | gzip) only APPROXIMATES the
# registry-compressed size, so the number is a consistent yardstick rather than
# a canonical one; M1 (LOCI-021) re-freezes the budgets against this exact tool.
readonly MB=1000000

report=0
image_filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) report=1; shift ;;
    --image) image_filter="$2"; shift 2 ;;
    -h | --help)
      echo "usage: size-check.sh [--report] [--image NAME]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# Measure compressed bytes for an image ref. Overridable for tests.
measure() {
  local ref="$1"
  if [[ -n "${LARAOCI_MEASURE_CMD:-}" ]]; then
    bash -c "$LARAOCI_MEASURE_CMD" _ "$ref"
  else
    docker save "$ref" | gzip -c | wc -c
  fi
}

registry="$(yq -r '.defaults.registry' "$CONFIG")"
tag="${LARAOCI_TAG:-local}"

mapfile -t budget_images < <(yq -r '.size_budgets | keys | .[]' "$CONFIG")

printf '%-12s %10s %10s %10s  %s\n' "IMAGE" "BUDGET_MB" "ACTUAL_MB" "DELTA_MB" "STATUS"
fail=0
for image in "${budget_images[@]}"; do
  [[ -n "$image_filter" && "$image" != "$image_filter" ]] && continue
  budget_mb="$(yq -r ".size_budgets.\"$image\"" "$CONFIG")"
  ref="$registry/$image:$tag"
  actual_bytes="$(measure "$ref")"
  actual_mb=$((actual_bytes / MB))
  delta_mb=$((actual_mb - budget_mb))
  status="ok"
  if ((actual_bytes > budget_mb * MB)); then
    status="OVER"
    fail=1
  fi
  printf '%-12s %10d %10d %10d  %s\n' "$image" "$budget_mb" "$actual_mb" "$delta_mb" "$status"
done

((report)) && exit 0
exit "$fail"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/bats/bin/bats tests/unit/size-check.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Lint**

Run: `shellcheck -S warning bin/size-check.sh && shfmt -d -i 2 -ci bin`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add bin/size-check.sh tests/unit/size-check.bats tests/fixtures/budgets.yml
git commit -m "feat(size-check): D17 budget enforcement with --report mode (LOCI-006)"
```

---

## Task 6: Reusable build workflow + stub Dockerfile (LOCI-007)

**Files:**
- Create: `.github/workflows/build.yml`
- Create: `tests/stub/Dockerfile`

**Interfaces:**
- Produces: a reusable `workflow_call` workflow. Inputs: `php`, `image`, `platforms`, `push` (bool), `cache_mode`, `dockerfile` (default `tests/stub/Dockerfile` for M0 - M1 switches to `images/<image>/Dockerfile`). Outputs: `image_ref`, `digest`. Sets up Buildx, wires GHA layer cache, threads `PHP_VERSION`/`DEBIAN_RELEASE` build args, and (M0) builds the stub. Verified end-to-end against the stub Dockerfile.

- [ ] **Step 1: Write `tests/stub/Dockerfile`**

```dockerfile
# Trivial image used only to verify the build pipeline end-to-end in M0.
# M1 replaces the per-image Dockerfiles under images/<name>/.
# hadolint ignore=DL3007
FROM alpine:3.20
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
RUN true
CMD ["true"]
```

- [ ] **Step 2: Verify the stub is hadolint-clean and builds**

Run: `hadolint tests/stub/Dockerfile && docker build -f tests/stub/Dockerfile --build-arg PHP_VERSION=8.4 -t laraoci-stub:local tests/stub`
Expected: hadolint prints nothing; the build succeeds.

- [ ] **Step 3: Write `.github/workflows/build.yml`**

```yaml
name: build

on:
  workflow_call:
    inputs:
      php:
        required: true
        type: string
      image:
        required: true
        type: string
      platforms:
        required: true
        type: string
      push:
        required: false
        type: boolean
        default: false
      cache_mode:
        required: false
        type: string
        default: max
      dockerfile:
        required: false
        type: string
        default: tests/stub/Dockerfile
    outputs:
      image_ref:
        description: Fully-qualified image reference
        value: ${{ jobs.build.outputs.image_ref }}
      digest:
        description: Image digest
        value: ${{ jobs.build.outputs.digest }}

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_ref: ${{ steps.meta.outputs.image_ref }}
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4

      - name: Compute image reference
        id: meta
        run: echo "image_ref=ghcr.io/laraoci/${{ inputs.image }}:${{ inputs.php }}-trixie" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: ${{ inputs.push }}
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ inputs.dockerfile }}
          platforms: ${{ inputs.platforms }}
          push: ${{ inputs.push }}
          load: ${{ !inputs.push }}
          tags: ${{ steps.meta.outputs.image_ref }}
          build-args: |
            PHP_VERSION=${{ inputs.php }}
            DEBIAN_RELEASE=trixie
          cache-from: type=gha
          cache-to: type=gha,mode=${{ inputs.cache_mode }}
```

- [ ] **Step 4: Lint the workflow**

Run: `actionlint .github/workflows/build.yml`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build.yml tests/stub/Dockerfile
git commit -m "feat(ci): reusable workflow_call build workflow with stub verification (LOCI-007)"
```

---

## Task 7: PR workflow (LOCI-008)

**Files:**
- Create: `.github/workflows/pr.yml`

**Interfaces:**
- Consumes: `bin/affected.sh`, `bin/matrix.sh`, `bin/size-check.sh`, and the reusable `build.yml`.
- Produces: a `pull_request` workflow. A `matrix` job runs `affected.sh` against the PR base, feeds the affected images into `matrix.sh --platform linux/amd64` (amd64 only), and exposes a `legs` output. A `build` job fans out via `fromJSON`, calling `build.yml` with `push: false` (build-and-load). A `size` job runs `size-check.sh --report` (advisory). Scan is advisory-only. **Acceptance:** a docs-only PR builds nothing (empty matrix -> build job skipped); a `runtime` PR builds all six images on amd64.

- [ ] **Step 1: Write `.github/workflows/pr.yml`**

```yaml
name: pr

on:
  pull_request:

permissions:
  contents: read
  packages: read

jobs:
  matrix:
    runs-on: ubuntu-latest
    outputs:
      legs: ${{ steps.gen.outputs.legs }}
      count: ${{ steps.gen.outputs.count }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install yq (mikefarah) and jq
        run: |
          sudo curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
            -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
          sudo apt-get update && sudo apt-get install -y jq

      - name: Resolve affected images and build the amd64 matrix
        id: gen
        run: |
          base="origin/${{ github.base_ref }}"
          mapfile -t images < <(bin/affected.sh --base "$base")
          if [[ ${#images[@]} -eq 0 ]]; then
            echo 'legs={"include":[]}' >> "$GITHUB_OUTPUT"
            echo 'count=0' >> "$GITHUB_OUTPUT"
            exit 0
          fi
          args=()
          for img in "${images[@]}"; do args+=(--image "$img"); done
          # matrix.sh takes a single --image; run it per image and merge.
          merged='{"include":[]}'
          for img in "${images[@]}"; do
            leg="$(bin/matrix.sh --image "$img" --platform linux/amd64)"
            merged="$(jq -c --argjson a "$merged" --argjson b "$leg" \
              '{include: ($a.include + $b.include)}' <<<'{}')"
          done
          {
            echo "legs=$merged"
            echo "count=$(jq '.include | length' <<<"$merged")"
          } >> "$GITHUB_OUTPUT"

  build:
    needs: matrix
    if: ${{ needs.matrix.outputs.count != '0' }}
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.matrix.outputs.legs) }}
    uses: ./.github/workflows/build.yml
    with:
      php: ${{ matrix.php }}
      image: ${{ matrix.image }}
      platforms: ${{ matrix.platform }}
      push: false
      cache_mode: max
      dockerfile: tests/stub/Dockerfile

  size:
    needs: matrix
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install yq (mikefarah)
        run: |
          sudo curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
            -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
      - name: Size report (advisory)
        run: bin/size-check.sh --report || true
```

> **M0 build target:** the `build` job points every leg at `tests/stub/Dockerfile` because no image Dockerfiles exist yet (M1). This keeps the pipeline genuinely green and end-to-end verifiable now; M1 (LOCI-011+) switches the `dockerfile` input to `images/<image>/Dockerfile`.

- [ ] **Step 2: Reconcile the `matrix.sh` single-`--image` limitation**

The generation step above loops `matrix.sh --image <img>` per affected image and merges with `jq`, because `matrix.sh` takes one `--image`. Confirm this produces the acceptance numbers locally:

Run:
```bash
# docs-only -> nothing
printf '%s\n' docs/x.md | bin/affected.sh   # expect: (empty)
# runtime -> all six, amd64 -> 6 legs
merged='{"include":[]}'
for img in $(printf '%s\n' images/runtime/Dockerfile | bin/affected.sh); do
  leg="$(bin/matrix.sh --image "$img" --platform linux/amd64)"
  merged="$(jq -c --argjson a "$merged" --argjson b "$leg" '{include: ($a.include + $b.include)}' <<<'{}')"
done
echo "$merged" | jq '.include | length'
```
Expected: the first command prints nothing; the final count prints `18` (6 images × 3 php on amd64). Note: a `runtime` PR builds all six *images* across the three PHP versions = 18 amd64 legs; "all six" in the acceptance refers to the image set, matched by `[.include[].image] | unique | length == 6`.

- [ ] **Step 3: Lint the workflow**

Run: `actionlint .github/workflows/pr.yml`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr.yml
git commit -m "feat(ci): PR pipeline - affected to matrix to build-and-load, amd64 only (LOCI-008)"
```

---

## Task 8: Repository scaffold docs (LOCI-001)

**Files:**
- Create: `README.md`, `LICENSE`, `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:**
- Produces: the human-facing scaffold. No code depends on it.

- [ ] **Step 1: Write `LICENSE`**

Use the MIT License text with `Copyright (c) 2026 LaraOCI`. (Full standard MIT text - the implementer pastes the canonical MIT license body verbatim with that copyright line.)

- [ ] **Step 2: Write `README.md`**

```markdown
# LaraOCI

Production-ready OCI images for Laravel applications: secure defaults, a single
shared runtime layer, and a maintained security posture. You bring `vendor/` and
your code; LaraOCI brings a correct PHP runtime, signal handling, logging, and
weekly rebuilds.

> **Status:** pre-release. M0 (foundations) builds the config-driven build
> pipeline; images arrive in M1+. See `docs/laraoci-Spec.md`.

## Image catalog

| Image | Parent | Purpose |
|-------|--------|---------|
| `runtime` | `php:X.Y-fpm-trixie` | Shared layer: extensions, user, ini, entrypoint, imagick policy |
| `cli` | `runtime` | Artisan commands, migrations, one-off tasks |
| `fpm` | `runtime` | PHP-FPM behind Nginx/Caddy/Traefik |
| `builder` | `runtime` | Composer + Node build toolchain (not for production runtime) |
| `queue` | `cli` | Laravel queue worker |
| `scheduler` | `cli` | Laravel scheduler |

## Repository layout

- `config/images.yml` - the single source of truth; CI derives the build matrix from it.
- `bin/` - `matrix.sh`, `affected.sh`, `size-check.sh`, and the entrypoint (M1).
- `images/` - per-image Dockerfiles (M1+).
- `tests/` - bats unit tests, structure tests, smoke tests, fixtures.
- `.github/workflows/` - `lint`, `build` (reusable), `pr`.

## Local development

    tests/bats/bin/bats tests/unit          # unit tests (needs mikefarah/yq v4 + jq)
    shellcheck -S warning bin/*.sh bin/lib/*.sh
    shfmt -d -i 2 -ci bin
    bin/matrix.sh | jq '.include | length'   # 36

## License

MIT - see `LICENSE`.
```

- [ ] **Step 3: Write `.github/PULL_REQUEST_TEMPLATE.md`**

```markdown
## Summary

<!-- What changes, and why. Reference the issue: LOCI-NNN. -->

## Checklist

- [ ] `shellcheck -S warning` and `shfmt -d -i 2 -ci` clean
- [ ] `tests/bats/bin/bats tests/unit` green
- [ ] `actionlint` clean on any workflow changes
- [ ] One commit per issue, message references `LOCI-NNN`
- [ ] No speculative generality - only what the spec calls for
```

- [ ] **Step 4: Commit**

```bash
git add README.md LICENSE .github/PULL_REQUEST_TEMPLATE.md
git commit -m "docs: repository scaffold - README, LICENSE, PR template (LOCI-001)"
```

---

## Task 9: Community health files (LOCI-002)

**Files:**
- Create: `SECURITY.md`, `CODE_OF_CONDUCT.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/feature_request.yml`, `.github/ISSUE_TEMPLATE/config.yml`

**Interfaces:**
- Produces: the health files. `SECURITY.md` states the CVE-triage posture and names the weekly rebuild (LOCI-049) as the actual security guarantee.

- [ ] **Step 1: Write `SECURITY.md`**

```markdown
# Security Policy

## Supported versions

LaraOCI publishes images for every PHP version marked `supported` in
`config/images.yml` (currently 8.3, 8.4, 8.5). A version receives security
updates while its upstream security window is open; when it closes, the version
moves to `deprecated` - existing dated tags remain but stop receiving rebuilds.

## The security guarantee is the weekly rebuild

Images accumulate CVEs after they are built, no matter how careful the original
build was. LaraOCI's primary control is an **unconditional weekly rebuild** of
all `supported` versions (see LOCI-049 / spec §9.3), which pulls current PHP and
Debian package fixes and republishes dated tags. Because ImageMagick lives in
the base layer (D13), this rebuild is not optional hygiene - it is the main
control on the largest CVE surface in the image.

## CVE triage posture

- Release builds hard-gate on fixable `CRITICAL` and `HIGH` vulnerabilities.
- PR builds scan advisory-only.
- On a scan failure, the scheduled run fails loudly and opens an issue rather
  than publishing.

## Reporting a vulnerability

Report privately via GitHub Security Advisories on this repository. Please do
not open a public issue for an unpatched vulnerability.
```

- [ ] **Step 2: Write `CODE_OF_CONDUCT.md`**

Use the Contributor Covenant v2.1 text, with the contact method set to a GitHub Security Advisory / the maintainers. (The implementer pastes the canonical Contributor Covenant 2.1 body verbatim.)

- [ ] **Step 3: Write `.github/ISSUE_TEMPLATE/config.yml`**

```yaml
blank_issues_enabled: false
```

- [ ] **Step 4: Write `.github/ISSUE_TEMPLATE/bug_report.yml`**

```yaml
name: Bug report
description: Something in a LaraOCI image or script is wrong
labels: ["type:infra"]
body:
  - type: input
    id: image
    attributes:
      label: Image and tag
      placeholder: ghcr.io/laraoci/fpm:8.4-trixie
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: What did you expect, and what happened?
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Minimal reproduction
      description: Commands, docker run invocation, or compose snippet.
    validations:
      required: true
```

- [ ] **Step 5: Write `.github/ISSUE_TEMPLATE/feature_request.yml`**

```yaml
name: Feature request
description: Propose a change, weighed against the non-goals in spec §14
labels: ["type:infra"]
body:
  - type: textarea
    id: problem
    attributes:
      label: What problem does this solve?
    validations:
      required: true
  - type: textarea
    id: proposal
    attributes:
      label: Proposal
      description: If it is `cli` plus a CMD, say so - it may be a thin derivative, not an image (D4).
    validations:
      required: true
```

- [ ] **Step 6: Commit**

```bash
git add SECURITY.md CODE_OF_CONDUCT.md .github/ISSUE_TEMPLATE
git commit -m "docs: community health files; SECURITY.md names weekly rebuild (LOCI-002)"
```

---

## Task 10: CONTRIBUTING.md and required-settings documentation (LOCI-010)

**Files:**
- Create: `CONTRIBUTING.md`

**Interfaces:**
- Produces: documentation of the required repository settings and branch protection. LOCI-010 produces *documentation* of the settings, not UI clicks.

- [ ] **Step 1: Write `CONTRIBUTING.md`**

```markdown
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

## Required repository settings

These are documented here rather than assumed; a maintainer configures them in
the GitHub UI under Settings.

### Branch protection - `main`

- Require a pull request before merging (at least 1 approval).
- Require status checks to pass before merging. **Required checks:**
  - `lint / shell`
  - `lint / actions`
  - `lint / bats`
  - `pr / matrix`
  - `pr / build` (when the affected set is non-empty)
- Require branches to be up-to-date before merging.
- Require conversation resolution before merging.
- Do not allow force pushes or deletions.

### Actions

- Workflow permissions: read repository contents by default; `packages: write`
  granted per-workflow only where a build pushes (release pipeline, M4).
- Allow GitHub Actions to create and approve pull requests: **off**.

### General

- Default branch: `main`.
- Automatically delete head branches after merge: **on**.
```

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: contributing guide and required branch-protection settings (LOCI-010)"
```

---

## Definition of done (from `docs/m0-foundations.md`)

- [ ] All ten issues (LOCI-001 … LOCI-010) closed with commits referencing them.
- [ ] `bin/matrix.sh` emits 36 legs, asserted by `tests/unit/matrix.bats`.
- [ ] `bin/affected.sh` passes tests for all four rows of the mapping table.
- [ ] The PR workflow builds nothing for a docs-only change (empty matrix -> build job skipped).
- [ ] `shellcheck`, `shfmt`, `actionlint`, and `bats` green in CI (`lint.yml`).
- [ ] `config/images.yml` reviewed and merged - M1 depends entirely on its shape.

## Verification pass (run once at the end, spec §self-review)

Run the full local gate:
```bash
shellcheck -S warning bin/*.sh bin/lib/*.sh
shfmt -d -i 2 -ci bin
tests/bats/bin/bats tests/unit
bin/matrix.sh | jq '.include | length'          # expect 36
printf '%s\n' docs/x.md | bin/affected.sh        # expect empty
printf '%s\n' images/runtime/Dockerfile | bin/affected.sh | wc -l   # expect 6
actionlint .github/workflows/*.yml
hadolint tests/stub/Dockerfile
```
Expected: all clean; matrix count `36`; docs-only affected set empty; runtime affected set 6 images.
