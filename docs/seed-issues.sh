#!/usr/bin/env bash
#
# LaraOCI - idempotent GitHub issue seeder
#
#   ./bin/seed-issues.sh                    # seed everything
#   ./bin/seed-issues.sh --milestone M1     # seed one milestone
#   ./bin/seed-issues.sh --dry-run          # print planned actions only
#   REPO=laraoci/laraoci ./bin/seed-issues.sh
#
# Idempotency: every issue body carries an <!-- LOCI-NNN --> marker. Existing
# issues are matched on that marker and edited in place; re-running converges
# rather than duplicating. Dependency references written as {{LOCI-NNN}} are
# resolved to #<number> in a second pass, after all issues exist.
#
# Requires: gh (authenticated), jq

set -euo pipefail

DRY_RUN=0
ONLY_MILESTONE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --milestone) ONLY_MILESTONE="$2"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *)           echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
echo "repo: $REPO"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MARKERS=()

# ---------------------------------------------------------------- definitions

define() {
  local marker="$1" milestone="$2" labels="$3" title="$4"
  MARKERS+=("$marker")
  printf '%s' "$title"     > "$WORK/$marker.title"
  printf '%s' "$milestone" > "$WORK/$marker.milestone"
  printf '%s' "$labels"    > "$WORK/$marker.labels"
  cat                      > "$WORK/$marker.body"
  printf '\n\n---\nSpec: `laraoci-spec.md`\n\n<!-- %s -->\n' "$marker" >> "$WORK/$marker.body"
}

# ---------------------------------------------------------------- M0

define LOCI-001 M0 "type:infra" "Repository scaffold" <<'BODY'
Establish the repository skeleton described in spec §12.

- [ ] `LICENSE` (MIT), `README.md` stub, `.editorconfig`, `.gitignore`
- [ ] Directory skeleton: `config/`, `images/`, `bin/`, `tests/`, `docs/`, `.github/workflows/`
- [ ] `CODEOWNERS`

**Acceptance:** directory tree matches §12; repo clones and `bin/` is executable.
BODY

define LOCI-002 M0 "type:infra,type:docs" "Community health files and issue forms" <<'BODY'
Standard org health infrastructure.

- [ ] `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`
- [ ] YAML issue forms: bug report, image request, extension request
- [ ] Pull request template
- [ ] `SECURITY.md` states the CVE triage posture and points at the weekly rebuild ({{LOCI-049}})

**Acceptance:** forms render on GitHub; security policy names a disclosure channel.
BODY

define LOCI-003 M0 "type:infra" "config/images.yml - schema and initial content" <<'BODY'
Single source of truth for the build matrix (spec §5).

- [ ] `defaults` block: registry, user 1000:1000, workdir, `debian: trixie`, platforms
- [ ] `php`: 8.3, 8.4, 8.5 - all `supported`, 8.4 `default: true`
- [ ] `extensions.core`: bcmath, exif, gd, imagick, intl, opcache, pcntl, pdo_mysql, pdo_pgsql, redis, sockets, zip
- [ ] `size_budgets` placeholders (frozen later by {{LOCI-021}})
- [ ] `images` with `parent` edges: runtime -> cli/fpm/builder, cli -> queue/scheduler
- [ ] Document that `php.<v>.debian` is a transition override, not a product axis (§3.1)

**Acceptance:** file parses with `yq`; every `parent` resolves to a defined image.
BODY

define LOCI-004 M0 "type:ci" "bin/matrix.sh - build matrix generation" <<'BODY'
Convert `config/images.yml` into a GitHub Actions JSON matrix.

- [ ] Emit one entry per (php × image × platform), skipping `deprecated` versions
- [ ] Topologically sort by `parent` so build order needs no hand maintenance
- [ ] Honour per-image `platforms` overrides
- [ ] `--php`, `--image`, `--platform` filters for local use

**Acceptance:** full matrix emits 36 legs for 3 versions × 6 images × 2 arches; output is valid input to `fromJSON()`.

Depends on {{LOCI-003}}.
BODY

define LOCI-005 M0 "type:ci" "bin/affected.sh - changed paths to affected images" <<'BODY'
Map a changed-file list to the set of images requiring rebuild, walking the `parent` graph (spec §9.1).

- [ ] A change under `images/runtime/` marks every descendant affected
- [ ] A change under `images/queue/` marks only `queue`
- [ ] Changes to `config/`, `bin/`, or the reusable workflow mark everything
- [ ] Changes under `docs/` or `tests/structure/` mark nothing to build

**Acceptance:** unit tests cover each case above.

Depends on {{LOCI-003}}.
BODY

define LOCI-006 M0 "type:ci" "bin/size-check.sh - image size budget enforcement" <<'BODY'
Implements D17 - makes "lightweight" testable rather than aspirational.

- [ ] Read `size_budgets` from `config/images.yml`
- [ ] Measure compressed size of a built image
- [ ] Non-zero exit on overrun, with the delta reported
- [ ] `--report` mode prints a table without failing, for PR annotation

**Acceptance:** fails a deliberately oversized fixture; passes within budget.

Depends on {{LOCI-003}}.
BODY

define LOCI-007 M0 "type:ci" "Reusable build workflow" <<'BODY'
`.github/workflows/build.yml` - the single build implementation both PR and release workflows call.

- [ ] `workflow_call` inputs: php, image, platforms, push, cache mode
- [ ] Buildx setup, layer cache wiring
- [ ] Build args threaded from `config/images.yml`
- [ ] Outputs: image ref, digest

**Acceptance:** callable from a throwaway workflow; builds a stub Dockerfile end to end.
BODY

define LOCI-008 M0 "type:ci" "PR workflow" <<'BODY'
`.github/workflows/pr.yml` - fast feedback path (spec §9.1).

- [ ] Matrix job runs `bin/affected.sh` then `bin/matrix.sh`
- [ ] amd64 only, GHA layer cache, build-and-load without push
- [ ] Vulnerability scan advisory only on PRs
- [ ] Size check in `--report` mode

**Acceptance:** a docs-only PR builds nothing; a `runtime` PR builds all six images.

Depends on {{LOCI-004}}, {{LOCI-005}}, {{LOCI-007}}.
BODY

define LOCI-009 M0 "type:ci,type:test" "Shell lint and script test harness" <<'BODY'
The `bin/` scripts are load-bearing; they need their own gate.

- [ ] `shellcheck` over `bin/*.sh` in CI
- [ ] `shfmt` formatting check
- [ ] `bats` (or equivalent) harness for the matrix/affected/size unit tests

**Acceptance:** lint and unit tests run on every PR and block merge.
BODY

define LOCI-010 M0 "type:infra" "Repository settings and branch protection" <<'BODY'
- [ ] Branch protection on `main`: required checks, no force push
- [ ] Required status checks: lint, structure tests, smoke tests
- [ ] Tag protection for release tags
- [ ] Actions permissions scoped to what the release workflow needs (`packages: write`, `id-token: write`, `attestations: write`)

**Acceptance:** settings documented in `CONTRIBUTING.md` so they are reproducible.
BODY

# ---------------------------------------------------------------- M1

define LOCI-011 M1 "type:image,area:runtime" "runtime: Dockerfile skeleton and upstream pin" <<'BODY'
Spec §7.1.

- [ ] `ARG PHP_VERSION`, `ARG DEBIAN_RELEASE=trixie`
- [ ] `FROM php:${PHP_VERSION}-cli-${DEBIAN_RELEASE}` - upstream trixie coverage for 8.3/8.4/8.5 is confirmed (§3.1)
- [ ] `WORKDIR /var/www/html`
- [ ] Record the resolved upstream digest for the `base.digest` label ({{LOCI-019}})

**Acceptance:** builds on all three PHP versions and reports the expected `php -v`.

Depends on {{LOCI-003}}, {{LOCI-007}}.
BODY

define LOCI-012 M1 "type:image,area:runtime" "runtime: non-root user and filesystem layout" <<'BODY'
Implements D8 - the fixed identity is a contract, not a default (spec §6.1).

- [ ] `laravel` user and group at UID/GID 1000, from `config/images.yml`
- [ ] `/var/www/html` owned by `laravel:laravel`
- [ ] `/usr/local/share/laraoci/` for shipped assets
- [ ] `USER laravel` before the final stage ends

**Acceptance:** `id -u` returns 1000; no process runs as root.

Depends on {{LOCI-011}}.
BODY

define LOCI-013 M1 "type:image,area:runtime" "runtime: core PHP extension installation" <<'BODY'
Install the §5 core set via `docker-php-extension-installer` (D12). All twelve extensions are supported on 8.3–8.5, so the set stays uniform across versions.

- [ ] Copy `install-php-extensions` from a pinned image tag
- [ ] Install the core set in a single layer
- [ ] Remove the installer binary, `*-dev` packages, and apt lists before the layer commits
- [ ] `pcntl` and `posix` must be present - without them queue workers cannot trap SIGTERM (§6.2)

**Acceptance:** `php -m` lists every core extension on all three versions.

Depends on {{LOCI-011}}.
BODY

define LOCI-014 M1 "type:image,type:security,area:runtime" "runtime: purge Ghostscript and guarantee its absence" <<'BODY'
Implements the second half of D13 (spec §3.2).

`install-php-extensions imagick` **installs `ghostscript` unconditionally on Debian** and marks it persistent - `--no-install-recommends` does not prevent this. Ghostscript is only a *Recommends* of `libmagickcore-7.q16-*`, never a Depends, so removing it is safe.

- [ ] `apt-get purge -y --auto-remove ghostscript` after the extension install
- [ ] **No `|| true`** - a failure here must fail the build
- [ ] Confirm `--auto-remove` reclaims `libgs*`, `poppler-data`, `fonts-urw-base35`
- [ ] Record the reclaimed size for the budget work in {{LOCI-021}}
- [ ] Verify imagick still loads and handles JPEG/PNG/WebP after the purge

**Acceptance:** `command -v gs` fails; `php -m` still lists imagick.

Depends on {{LOCI-013}}.
BODY

define LOCI-015 M1 "type:image,type:security,area:runtime" "runtime: hardened ImageMagick policy" <<'BODY'
Implements the first half of D13 (spec §3.2). Trixie ships **ImageMagick 7**, so the policy lands at `/etc/ImageMagick-7/policy.xml`.

- [ ] Add `config/imagemagick/policy.xml` per §3.2: all delegates denied; PS/PS2/PS3/EPS/PDF/XPS, MSL/MVG/MAGICK/TEXT/SHOW/WIN/PLT, and URL/HTTP/HTTPS/FTP coders denied; `path` pattern `@*` denied
- [ ] Resource limits: memory, map, width, height, area, disk, time, `thread=1`
- [ ] Install to whichever `/etc/ImageMagick-*` directory exists, so a suite bump does not silently drop the policy
- [ ] `ENV MAGICK_THREAD_LIMIT=1 MAGICK_TMPDIR=/tmp` - thread limiting is a correctness fix, not only a security one: N FPM children each opening an OpenMP pool will thrash a CPU-limited container

**Acceptance:** a `PDF:` open and an `@`-prefixed indirect read both throw `ImagickException`; a JPEG resize succeeds.

Depends on {{LOCI-013}}.
BODY

define LOCI-016 M1 "type:image,area:runtime" "runtime: php.ini baseline template" <<'BODY'
Spec §6.5.

- [ ] `config/php/zz-laraoci.ini.template` with the §6.5 baseline
- [ ] `expose_php=Off`, `display_errors=Off`, `log_errors=On`, `error_log=/proc/self/fd/2`
- [ ] Opcache: `validate_timestamps=0`, `enable_cli=1`, `memory_consumption=192`, `max_accelerated_files=20000`, `jit=disable`
- [ ] `realpath_cache_size=4096K`, `realpath_cache_ttl=600`
- [ ] No `disable_functions` - Laravel uses `proc_open`/`exec` legitimately

**Acceptance:** filename sorts last in `conf.d`, so a user-mounted file wins.

Depends on {{LOCI-011}}.
BODY

define LOCI-017 M1 "type:image,area:runtime" "runtime: entrypoint and envsubst config rendering" <<'BODY'
Spec §6.4.

- [ ] `bin/entrypoint.sh` renders templates from `/usr/local/share/laraoci/templates/` with `envsubst`
- [ ] Allowlist only the documented `PHP_*` variables; everything else passes through untouched
- [ ] Defaults applied when unset, per the §6.4 table
- [ ] `exec "$@"` at the end - no wrapper process left in the tree

**Acceptance:** overriding `PHP_MEMORY_LIMIT` changes `php -i` output; unset variables produce the documented defaults.

Depends on {{LOCI-016}}.
BODY

define LOCI-018 M1 "type:image,area:runtime" "runtime: tini init and exec-form entrypoint" <<'BODY'
Implements D9 (spec §6.2).

- [ ] `tini` installed
- [ ] `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/laraoci-entrypoint"]` - exec form
- [ ] `STOPSIGNAL SIGTERM` stated explicitly rather than inherited
- [ ] No shell-form `CMD` anywhere in the image tree

**Acceptance:** `tini` is PID 1; SIGTERM reaches the application process.

Depends on {{LOCI-017}}.
BODY

define LOCI-019 M1 "type:image,area:runtime" "runtime: OCI image labels" <<'BODY'
Spec §11.

- [ ] `org.opencontainers.image.{source,revision,created,version,licenses,description,documentation}`
- [ ] `org.opencontainers.image.base.name` and `base.digest` - so consumers can identify the exact upstream `php:` image
- [ ] Labels applied in the reusable workflow, not hand-written per Dockerfile

**Acceptance:** `docker inspect` shows all labels populated with real values, not placeholders.

Depends on {{LOCI-011}}, {{LOCI-007}}.
BODY

define LOCI-020 M1 "type:test" "Structure test harness" <<'BODY'
`container-structure-test` wiring for all images (spec §10.1).

- [ ] Harness runs a per-image YAML file against a built image
- [ ] Shared assertions factored so every image inherits the runtime contract checks
- [ ] Wired into the PR workflow as a required check

**Acceptance:** harness runs green on the runtime image and red on a deliberately broken one.

Depends on {{LOCI-008}}.
BODY

define LOCI-021 M1 "type:test,area:runtime" "runtime: structure tests and size budget freeze" <<'BODY'
Assert the §6 runtime contract, and close open question §17.1.

- [ ] Runs as UID 1000; `/var/www/html` owned by `laravel`
- [ ] `pcntl`, `posix`, `opcache`, `imagick` loaded
- [ ] `opcache.validate_timestamps=0`, `expose_php=Off`
- [ ] **ImageMagick major version is 7** via `Imagick::getVersion()`
- [ ] **Policy asserted through PHP, not `identify`** - the image contains no ImageMagick CLI tools, so `identify -list policy` is unavailable. Open a `PDF:` pseudo-image and an `@`-prefixed indirect read; both must throw
- [ ] `command -v gs` fails
- [ ] `tini` is PID 1
- [ ] **Measure real compressed sizes on all three versions and replace the `size_budgets` placeholders in `config/images.yml`**
- [ ] Report how much of the footprint is `libmagickcore-*-extra` specifically - that number is the input to {{LOCI-056}}

**Acceptance:** structure tests green on 8.3/8.4/8.5; budgets committed as measured values.

Depends on {{LOCI-014}}, {{LOCI-015}}, {{LOCI-018}}, {{LOCI-020}}.
BODY

# ---------------------------------------------------------------- M2

define LOCI-022 M2 "type:image,area:cli" "cli image" <<'BODY'
Spec §7.2. `runtime` plus a default command - nothing else.

- [ ] `CMD ["php", "artisan", "list"]`
- [ ] **No Composer** (D6) - asserted in structure tests
- [ ] Structure tests inherit the runtime contract assertions

**Acceptance:** `docker run --rm cli php -v` works; `command -v composer` fails.

Depends on {{LOCI-021}}.
BODY

define LOCI-023 M2 "type:image,area:fpm" "fpm: SAPI installation" <<'BODY'
Spec §7.3. FPM installs on top of `runtime` rather than switching upstream base, so all images share one root (§2.2).

- [ ] Install the FPM SAPI
- [ ] `EXPOSE 9000`
- [ ] Global config: `daemonize = no`, `error_log = /proc/self/fd/2`
- [ ] Entrypoint runs `php-fpm` in the foreground under tini

**Acceptance:** container starts, stays in the foreground, and logs to stderr.

Depends on {{LOCI-021}}.
BODY

define LOCI-024 M2 "type:image,area:fpm" "fpm: pool configuration template" <<'BODY'
Spec §7.3. **`clear_env = no` is the single most important line in this repository** - with the FPM default the application sees none of the container environment and silently falls back to defaults.

- [ ] `config/php/zz-laraoci-fpm.conf.template` rendered by the entrypoint
- [ ] `clear_env = no`
- [ ] `catch_workers_output = yes`, `decorate_workers_output = no` - the latter keeps FPM from prefixing worker lines and breaking JSON log parsing
- [ ] `access.log = /proc/self/fd/2`
- [ ] `pm.*` driven by the §6.4 environment variables
- [ ] `ping.path = /fpm-ping`, `pm.status_path = /fpm-status`

**Acceptance:** rendered pool contains `clear_env = no`; `pm.max_children` responds to the env var.

Depends on {{LOCI-023}}, {{LOCI-017}}.
BODY

define LOCI-025 M2 "type:image,area:fpm" "fpm: healthcheck" <<'BODY'
Spec §7.3. A container that cannot report its own health is worse than one 200 KB larger.

- [ ] `libfcgi-bin` installed in `fpm` only
- [ ] `HEALTHCHECK` using `cgi-fcgi -bind -connect 127.0.0.1:9000` against `/fpm-ping`
- [ ] Sensible interval/timeout/retries/start-period

**Acceptance:** healthcheck reports healthy when up and unhealthy when the pool is stopped.

Depends on {{LOCI-024}}.
BODY

define LOCI-026 M2 "type:image,area:builder" "builder image" <<'BODY'
Spec §7.4. Implements D3 - and D3a: **multi-arch**, reversing the earlier amd64-only position. Native ARM64 runners remove the QEMU penalty, and Apple Silicon developers would otherwise emulate the whole `composer install` and `npm ci` locally.

- [ ] Composer, git, unzip, Node LTS, npm
- [ ] `COMPOSER_HOME` and the npm cache path documented as part of the runtime contract, so consumers can mount BuildKit caches
- [ ] `org.opencontainers.image.description` states plainly that this is **not a production runtime**
- [ ] Built for both platforms

**Acceptance:** a `composer install` and `npm ci` complete on both arches; the resulting `vendor/` copies cleanly into `fpm`.

Depends on {{LOCI-021}}.
BODY

define LOCI-027 M2 "type:test" "Test fixture: minimal Laravel application" <<'BODY'
`tests/fixtures/app` - the substrate for every smoke test (spec §10.2).

- [ ] Minimal Laravel skeleton, committed
- [ ] A route that echoes an `env()` value, for {{LOCI-030}}
- [ ] A job that sleeps, for the SIGTERM test in {{LOCI-036}}
- [ ] A per-minute scheduled task, for {{LOCI-037}}
- [ ] SQLite configured so no external service is needed

**Acceptance:** fixture boots under `cli` and serves under `fpm`.
BODY

define LOCI-028 M2 "type:test" "Smoke test harness" <<'BODY'
Spec §10.2.

- [ ] Compose-based harness wiring builder -> cli -> fpm -> nginx, plus queue and scheduler
- [ ] Deterministic teardown; no leaked containers or volumes on failure
- [ ] Runs in the PR workflow as a required check
- [ ] Readable failure output - these tests are the project's real specification

**Acceptance:** harness runs locally and in CI with identical results.

Depends on {{LOCI-027}}, {{LOCI-008}}.
BODY

define LOCI-029 M2 "type:test" "Smoke: builder to cli to fpm request path" <<'BODY'
Spec §10.2 steps 1–3.

- [ ] `builder` -> `composer install`, `npm ci && npm run build`
- [ ] `cli` -> `artisan migrate` on SQLite, `artisan about`
- [ ] `fpm` behind a throwaway Nginx -> HTTP 200 on `/`
- [ ] `/fpm-ping` returns `pong`

**Acceptance:** all four green on all three PHP versions.

Depends on {{LOCI-028}}, {{LOCI-022}}, {{LOCI-025}}, {{LOCI-026}}.
BODY

define LOCI-030 M2 "type:test,area:fpm" "Smoke: environment passthrough (clear_env regression)" <<'BODY'
Spec §10.3. This gets its own named test because **the failure mode is silent** - the application does not error, it just reads defaults.

- [ ] Set an arbitrary env var on the `fpm` container
- [ ] Hit the fixture route that echoes `env()`
- [ ] Assert the value is visible

**Acceptance:** test fails if `clear_env = no` is removed from the pool template.

Depends on {{LOCI-029}}, {{LOCI-024}}.
BODY

define LOCI-031 M2 "type:test,type:security,area:runtime" "Smoke: imagick operation and policy denial" <<'BODY'
Spec §10.2 step 6 - proves D13 both ways.

- [ ] Resize a JPEG through the `Imagick` class and assert the output
- [ ] Assert a crafted `PDF:` open throws
- [ ] Assert an `@file` indirect read throws
- [ ] Assert `gs` is absent

**Acceptance:** legitimate image work succeeds; every denied path throws rather than silently degrading.

Depends on {{LOCI-029}}, {{LOCI-015}}.
BODY

# ---------------------------------------------------------------- M3

define LOCI-032 M3 "type:image,area:queue" "queue image" <<'BODY'
Spec §7.5. Implements D4 - `FROM cli` plus a `CMD`, nothing more.

- [ ] `CMD ["php","artisan","queue:work","--no-interaction","--tries=3","--max-time=3600","--rest=0.1"]`
- [ ] `--max-time` bounds worker lifetime so leaks and stale state cannot accumulate
- [ ] **No `HEALTHCHECK`** - a queue worker has no meaningful synchronous health signal, and a naive one is worse than none

**Acceptance:** processes a job end to end against the fixture.

Depends on {{LOCI-022}}.
BODY

define LOCI-033 M3 "type:image,area:scheduler" "scheduler image" <<'BODY'
Spec §7.6. Implements D10 - `schedule:work`, no cron, no supervisor.

- [ ] `CMD ["php","artisan","schedule:work","--no-interaction"]`
- [ ] Document the **exactly one replica** constraint prominently; two scheduler containers double-fire every task

**Acceptance:** a per-minute fixture task fires once per minute.

Depends on {{LOCI-022}}.
BODY

define LOCI-034 M3 "type:image,area:runtime" "Preload script" <<'BODY'
Implements D14 (spec §7.7). Ships at `/usr/local/share/laraoci/preload.php`, **inert unless** `PHP_OPCACHE_PRELOAD` names it.

- [ ] Walk `LARAOCI_PRELOAD_PATHS` under `LARAOCI_PRELOAD_ROOT`, skipping `LARAOCI_PRELOAD_IGNORE`
- [ ] Default paths: `vendor/laravel/framework/src/Illuminate,vendor/composer`
- [ ] **`vendor/symfony` deliberately excluded** - Illuminate already pulls in the Symfony components actually used; compiling the full tree loads Console/Mailer/HttpKernel subtrees most apps never touch, and is the largest source of benign "unlinked class" skips
- [ ] Swallow preload warnings so startup logs stay clean; report compiled/skipped counts to stderr
- [ ] No-op safely when `vendor/` is absent

**Acceptance:** reports a non-zero compiled count against the fixture; exits cleanly against an empty root.

Depends on {{LOCI-021}}.
BODY

define LOCI-035 M3 "type:docs,area:runtime" "Preload environment plumbing and documentation" <<'BODY'
Spec §7.7.

- [ ] `PHP_OPCACHE_PRELOAD` and the three `LARAOCI_PRELOAD_*` variables in the entrypoint allowlist
- [ ] Document the paired `PHP_OPCACHE_MEMORY_CONSUMPTION=320` bump
- [ ] Document that `opcache.preload_user` is **not** needed - that directive only applies when the FPM master runs as root, and LaraOCI runs as `laravel` throughout
- [ ] Document that a container restart is required to change anything preloaded
- [ ] Show `opcache_get_status()['preload_statistics']` as the way to tune, rather than asserting a number

**Acceptance:** docs let a reader enable preload and measure the result without guessing.

Depends on {{LOCI-034}}.
BODY

define LOCI-036 M3 "type:test,area:queue" "Smoke: queue graceful shutdown under SIGTERM" <<'BODY'
Spec §10.2 step 4 - **the pcntl regression test**, and the highest-value test in the suite. Without `pcntl`, every deploy truncates in-flight jobs.

- [ ] Dispatch a long-running fixture job
- [ ] Send SIGTERM mid-execution
- [ ] Assert the job **completes**, not that the container merely exits
- [ ] Assert exit within the grace window

**Acceptance:** test fails if `pcntl` is removed from the extension set.

Depends on {{LOCI-032}}, {{LOCI-028}}.
BODY

define LOCI-037 M3 "type:test,area:scheduler" "Smoke: scheduler single-fire" <<'BODY'
Spec §10.2 step 5.

- [ ] Run the scheduler for ~70 seconds
- [ ] Assert exactly one execution of the per-minute fixture task - not zero, not two

**Acceptance:** green in CI without flaking on timing.

Depends on {{LOCI-033}}, {{LOCI-028}}.
BODY

define LOCI-038 M3 "type:test,area:runtime" "Smoke: preload enabled and empty-vendor safety" <<'BODY'
Spec §10.2 step 7.

- [ ] Boot `fpm` with `PHP_OPCACHE_PRELOAD` set; assert a non-zero preloaded count and HTTP 200 still served
- [ ] Boot with an empty `vendor/`; assert the container **still starts** rather than crash-looping

**Acceptance:** both paths green.

Depends on {{LOCI-034}}, {{LOCI-029}}.
BODY

define LOCI-039 M3 "type:docs" "Operational documentation: grace periods, replicas, opcache" <<'BODY'
The failure modes that will otherwise generate every support issue.

- [ ] **Grace period must exceed job timeout** - Laravel's 60s default against Docker's 10s grace kills in-flight jobs on every deploy. Show `stop_grace_period` and `terminationGracePeriodSeconds`
- [ ] **Scheduler: exactly one replica**, and what HA actually requires (`withoutOverlapping` plus a shared cache lock - application config, not image config)
- [ ] **`validate_timestamps=0` means the container must be replaced to pick up code changes** - flagged loudly for anyone bind-mounting source
- [ ] Shared `storage/` volume ownership and the fixed UID 1000

**Acceptance:** each item has a copy-pasteable Compose and Kubernetes example.

Depends on {{LOCI-036}}, {{LOCI-037}}.
BODY

# ---------------------------------------------------------------- M4

define LOCI-040 M4 "type:ci,area:pipeline" "Multi-arch builds on native runners" <<'BODY'
Spec §9.2.

- [ ] amd64 and arm64 on native GitHub-hosted runners; QEMU only as documented fallback
- [ ] Applies to `builder` too, per D3a
- [ ] Per-arch build caching

**Acceptance:** all 36 legs build; arm64 legs run natively.

Depends on {{LOCI-007}}, {{LOCI-026}}.
BODY

define LOCI-041 M4 "type:ci,area:pipeline" "Multi-platform manifest publication" <<'BODY'
- [ ] Assemble manifest lists from per-arch digests
- [ ] Push to GHCR under the correct package per image type
- [ ] Manifest creation gated on **all** arch legs succeeding

**Acceptance:** `docker manifest inspect` shows both platforms on every published tag.

Depends on {{LOCI-040}}.
BODY

define LOCI-042 M4 "type:ci,type:security,area:pipeline" "SBOM and build provenance attestations" <<'BODY'
Spec §11.

- [ ] SPDX SBOM per image, attached as an attestation
- [ ] SLSA build provenance, `mode=max`
- [ ] Attestations attached to the manifest, not only per-arch images

**Acceptance:** SBOM and provenance retrievable for a published tag.

Depends on {{LOCI-041}}.
BODY

define LOCI-043 M4 "type:ci,type:security,area:pipeline" "Cosign keyless signing" <<'BODY'
Spec §11.

- [ ] Cosign keyless signing via GitHub OIDC
- [ ] `id-token: write` permission scoped to the release workflow
- [ ] Signature covers the manifest list

**Acceptance:** `cosign verify` succeeds with the expected identity and issuer.

Depends on {{LOCI-041}}.
BODY

define LOCI-044 M4 "type:ci,type:security,area:pipeline" "Vulnerability scan gate" <<'BODY'
Spec §9.2. Now load-bearing: imagick sits in the base layer, so this is the primary control on the largest CVE surface in the image.

- [ ] Trivy or Grype in the release workflow
- [ ] **Hard fail** on fixable CRITICAL and HIGH
- [ ] Results uploaded to GitHub code scanning
- [ ] Documented, time-boxed exception process - not an open-ended ignore file

**Acceptance:** a deliberately vulnerable fixture fails the gate.

Depends on {{LOCI-040}}.
BODY

define LOCI-045 M4 "type:ci,area:pipeline" "Tagging policy implementation" <<'BODY'
Spec §8. Without immutable tags, "consistent deployment environments" is unachievable.

- [ ] Rolling: `:8.4`, `:8.4-trixie`, and `:latest` for the default version only
- [ ] Immutable: `:8.4-trixie-YYYYMMDD` and `:8.4.23-trixie-YYYYMMDD`
- [ ] **Dated tags are never overwritten** - a same-day rebuild appends `-2`
- [ ] One GHCR package per image type

**Acceptance:** a second same-day release produces `-2` rather than clobbering.

Depends on {{LOCI-041}}.
BODY

define LOCI-046 M4 "type:ci,area:pipeline" "Rolling tag repoint gated on full matrix" <<'BODY'
Spec §8. A partially-failed matrix must never leave `:8.4` pointing at a half-updated set.

- [ ] Repoint runs as a separate job with `needs` on every matrix leg
- [ ] Skipped entirely if any leg failed
- [ ] Idempotent - safe to re-run

**Acceptance:** an induced single-leg failure leaves all rolling tags untouched.

Depends on {{LOCI-045}}.
BODY

define LOCI-047 M4 "type:ci,area:pipeline" "Release workflow and release notes" <<'BODY'
- [ ] `.github/workflows/release.yml` on tag push and manual dispatch
- [ ] Full matrix, size gate, scan gate, attestations, signing, tagging, repoint
- [ ] Generated release notes listing PHP patch levels, upstream base digests, and any extension changes
- [ ] Extension additions or removals called out explicitly - they are a minor version bump per §13

**Acceptance:** first end-to-end signed multi-arch release published to GHCR.

Depends on {{LOCI-042}}, {{LOCI-043}}, {{LOCI-044}}, {{LOCI-046}}, {{LOCI-006}}.
BODY

define LOCI-048 M4 "type:docs,type:security" "GHCR package configuration and verification docs" <<'BODY'
An unverifiable signature is decorative.

- [ ] Package visibility and description per image
- [ ] README section: `cosign verify` with the exact expected identity and issuer
- [ ] How to retrieve and read the SBOM
- [ ] How to resolve a rolling tag to a digest and pin it

**Acceptance:** a reader can verify a published image start to finish from the README alone.

Depends on {{LOCI-047}}.
BODY

# ---------------------------------------------------------------- M5

define LOCI-049 M5 "type:ci,type:security,area:pipeline" "Scheduled weekly rebuild workflow" <<'BODY'
Spec §9.3. **This is what keeps "secure" true.** An image built once accumulates CVEs no matter how careful the original build was.

- [ ] Weekly cron over all `supported` versions
- [ ] **Unconditional** - no "did upstream change" check, which would miss package-level updates that do not move the upstream digest
- [ ] Produces a new dated tag and repoints rolling tags
- [ ] On scan failure: fail loudly and open an issue rather than publishing

**Acceptance:** one full cycle completes and rolling tags move.

Depends on {{LOCI-047}}.
BODY

define LOCI-050 M5 "type:ci" "PHP version deprecation tooling" <<'BODY'
Spec §13.

- [ ] Flipping `status: deprecated` removes a version from scheduled rebuilds while leaving its dated tags intact
- [ ] Rolling tag freezes; README records the freeze date
- [ ] Advance-warning issue template for deprecations

**Acceptance:** a deprecated version stops rebuilding and its existing tags still resolve.

Depends on {{LOCI-049}}, {{LOCI-003}}.
BODY

define LOCI-051 M5 "type:docs" "Documentation site" <<'BODY'
- [ ] Quickstart per image
- [ ] The full §6 runtime contract, presented as a contract
- [ ] Multi-stage build recipes
- [ ] Compose and Kubernetes examples
- [ ] Tuning: FPM `pm.*`, opcache, preload
- [ ] Troubleshooting, led by the silent failures: `clear_env`, grace periods, `validate_timestamps`

**Acceptance:** published and linked from every image description.

Depends on {{LOCI-039}}, {{LOCI-048}}.
BODY

define LOCI-052 M5 "type:docs" "Consumer Renovate and Dependabot examples" <<'BODY'
Immutable tags are only usable if bumping them is automated.

- [ ] Renovate config matching LaraOCI's dated tag format
- [ ] Dependabot equivalent
- [ ] Digest-pinning example for supply-chain-strict consumers

**Acceptance:** configs verified against a sample consumer repository.

Depends on {{LOCI-045}}.
BODY

define LOCI-053 M5 "type:docs" "README: positioning and migration notes" <<'BODY'
- [ ] What LaraOCI is and is not (§14), including why `builder` is a deliberate exception
- [ ] **ImageMagick 7 callout** - these images link imagick against IM7, not IM6. Anyone arriving from a bookworm-based image is crossing a major ImageMagick version at the same time, and a handful of Imagick API behaviours differ
- [ ] **PDF/PostScript rasterisation is out of scope** and why (no Ghostscript), plus how to add it deliberately in a consumer layer
- [ ] Production guidance: dated tags or digests, never rolling

**Acceptance:** migration notes reviewed against the IM6->IM7 differences before publication.

Depends on {{LOCI-051}}.
BODY

# ---------------------------------------------------------------- M6

define LOCI-054 M6 "type:docs,area:pipeline" "Design note: FrankenPHP second root" <<'BODY'
Implements D16 (spec §3.3). **Design note first, implementation second.**

FrankenPHP ships as `dunglas/frankenphp` with its own embedded PHP build, so it cannot descend from `laraoci/runtime` without either compiling from source - a large ongoing maintenance commitment - or duplicating the extension layer. This breaks §2.2 for exactly one image, and the decision is to accept the second root rather than distort the rest of the design.

The note must cover:

- [ ] How the §6 runtime contract is upheld on a base LaraOCI does not control - UID, logging, signals, env passthrough
- [ ] The `clear_env` equivalent, and whether one exists
- [ ] Worker mode and the Laravel Octane driver
- [ ] Whether the extension set can be kept at parity, and what happens when it cannot
- [ ] Whether "the server is the SAPI" holds up as the §14 carve-out, or whether this genuinely crosses the non-goal

**Acceptance:** note reviewed and merged before any `images/frankenphp/` work begins.
BODY

define LOCI-055 M6 "type:infra" "PHP 8.6 readiness" <<'BODY'
Closes open question §17.4. An 8.6 alpha is already built upstream with full trixie coverage, so GA should be a one-line `config/images.yml` addition.

- [ ] Confirm the intent to add 8.6 at GA as a fourth `supported` version
- [ ] Note the consequence: 36 release legs become 48, which makes `bin/affected.sh` load-bearing rather than a nicety
- [ ] Verify the core extension set - imagick especially - is available on 8.6 before committing
- [ ] Decide whether 8.3 moves to `deprecated` at the same time

**Acceptance:** decision recorded in the spec's decision register before the first 8.6 build.

Depends on {{LOCI-050}}.
BODY

define LOCI-056 M6 "type:image,area:runtime" "Evaluate -slim variant" <<'BODY'
Closes open question §17.1/§17.3. **Evidence-driven - do not pre-emptively engineer.**

`libmagickcore-*-extra` brings DjVu, WMF, OpenEXR, and RAW decoders that no Laravel application asked for, and it is unavoidable via the `install-php-extensions` path. If {{LOCI-021}} shows it dominates the size overrun:

- [ ] Compare a hand-rolled apt install that skips `-extra` against the installer path
- [ ] Weigh the maintenance cost of hand-rolling against the size and parser-surface saving
- [ ] If a `-slim` variant is warranted, publish it **without imagick** rather than reversing the default - reversing would break consumers, and reopening the matrix should happen on evidence

**Acceptance:** a decision recorded either way, with the measured numbers attached.

Depends on {{LOCI-021}}.
BODY

# ------------------------------------------------------------------ execution

declare -A MS_DESC=(
  [M0]="Foundations - scaffold, config, matrix generation, PR pipeline"
  [M1]="Runtime - the shared base layer and its contract"
  [M2]="CLI, FPM, Builder - the first consumable images"
  [M3]="Workers and preload - queue, scheduler, opcache preload"
  [M4]="Release pipeline - multi-arch, attestations, signing, tagging"
  [M5]="Maintenance - scheduled rebuilds, deprecation, documentation"
  [M6]="Post-v1 - FrankenPHP, PHP 8.6, slim variant"
)

LABELS=(
  "type:infra|0e8a16|Repository and project infrastructure"
  "type:image|1d76db|Image definition work"
  "type:ci|5319e7|Build and release pipeline"
  "type:test|fbca04|Structure, smoke, and unit tests"
  "type:docs|006b75|Documentation"
  "type:security|b60205|Security posture and supply chain"
  "area:runtime|c5def5|Shared runtime layer"
  "area:cli|c5def5|CLI image"
  "area:fpm|c5def5|FPM image"
  "area:builder|c5def5|Builder image"
  "area:queue|c5def5|Queue image"
  "area:scheduler|c5def5|Scheduler image"
  "area:pipeline|c5def5|Build and release pipeline"
)

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

echo "==> ensuring labels"
existing_labels="$(gh label list --repo "$REPO" --limit 300 --json name -q '.[].name' 2>/dev/null || true)"
for spec in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$spec"
  if grep -qxF "$name" <<< "$existing_labels"; then
    run gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null
  else
    run gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null
  fi
done

echo "==> ensuring milestones"
for ms in M0 M1 M2 M3 M4 M5 M6; do
  num="$(gh api "repos/$REPO/milestones?state=all&per_page=100" --jq ".[] | select(.title==\"$ms\") | .number" 2>/dev/null || true)"
  if [[ -z "$num" ]]; then
    run gh api "repos/$REPO/milestones" -f title="$ms" -f description="${MS_DESC[$ms]}" >/dev/null
  fi
done

echo "==> caching existing issues"
if [[ "$DRY_RUN" == "1" ]]; then
  echo '[]' > "$WORK/existing.json"
else
  gh issue list --repo "$REPO" --state all --limit 1000 --json number,body > "$WORK/existing.json"
fi

find_issue() {
  jq -r --arg m "<!-- $1 -->" \
    '[.[] | select(.body != null and (.body | contains($m)))] | .[0].number // empty' \
    "$WORK/existing.json"
}

# --- pass 1: ensure every issue exists ---------------------------------------
echo "==> pass 1: upserting issues"
: > "$WORK/map"

for marker in "${MARKERS[@]}"; do
  ms="$(cat "$WORK/$marker.milestone")"
  [[ -n "$ONLY_MILESTONE" && "$ms" != "$ONLY_MILESTONE" ]] && continue

  title="$(cat "$WORK/$marker.title")"
  num="$(find_issue "$marker")"

  if [[ -n "$num" ]]; then
    echo "  = $marker -> #$num  $title"
  elif [[ "$DRY_RUN" == "1" ]]; then
    echo "  + $marker (would create)  $title"
    num="0"
  else
    label_args=()
    IFS=',' read -ra labs <<< "$(cat "$WORK/$marker.labels")"
    for l in "${labs[@]}"; do label_args+=(--label "$l"); done

    url="$(gh issue create --repo "$REPO" \
             --title "$title" \
             --body-file "$WORK/$marker.body" \
             --milestone "$ms" \
             "${label_args[@]}")"
    num="${url##*/}"
    echo "  + $marker -> #$num  $title"
  fi

  echo "$marker $num" >> "$WORK/map"
done

# --- pass 2: resolve {{LOCI-NNN}} and correct drift ---------------------------
echo "==> pass 2: resolving dependency links"

for marker in "${MARKERS[@]}"; do
  ms="$(cat "$WORK/$marker.milestone")"
  [[ -n "$ONLY_MILESTONE" && "$ms" != "$ONLY_MILESTONE" ]] && continue

  num="$(awk -v m="$marker" '$1==m {print $2}' "$WORK/map")"
  [[ -z "$num" || "$num" == "0" ]] && continue

  cp "$WORK/$marker.body" "$WORK/$marker.resolved"
  while read -r m n; do
    [[ "$n" == "0" ]] && continue
    sed -i.bak "s|{{$m}}|#$n|g" "$WORK/$marker.resolved"
  done < "$WORK/map"
  rm -f "$WORK/$marker.resolved.bak"

  # Unresolved references mean the target lives in a milestone not being seeded.
  if grep -q '{{LOCI-' "$WORK/$marker.resolved"; then
    sed -i.bak 's|{{\(LOCI-[0-9]*\)}}|`\1`|g' "$WORK/$marker.resolved"
    rm -f "$WORK/$marker.resolved.bak"
  fi

  label_args=()
  IFS=',' read -ra labs <<< "$(cat "$WORK/$marker.labels")"
  for l in "${labs[@]}"; do label_args+=(--label "$l"); done

  run gh issue edit "$num" --repo "$REPO" \
      --body-file "$WORK/$marker.resolved" \
      --milestone "$ms" \
      "${label_args[@]}" >/dev/null

  echo "  ~ $marker -> #$num"
done

echo "==> done (${#MARKERS[@]} issues defined)"
