# LaraOCI

![Dynamic JSON Badge](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Flaraoci%2Fruntime%2Fmain%2F.github%2Fbadges%2Fdocker-pulls.json&query=%24.message&label=Docker%20pulls&color=blue)

Production-ready OCI images for Laravel applications: secure defaults, a single
shared runtime layer, and a maintained security posture. You bring `vendor/` and
your code; LaraOCI brings a correct PHP runtime, signal handling, logging, and
weekly rebuilds.

> **Status:** pre-release. M0 (foundations), M1 (the shared `runtime` layer),
> M2 (`cli`, `fpm`, `builder`) and M3 (`queue`, `scheduler`, opcache preload) are
> complete; publishing, signing and scanning arrive in M4. **Nothing is published
> yet** - the image references below are what M4 will push; until then images are
> built locally with `bin/build-chain.sh`. See `docs/laraoci-Spec.md`.

## Image catalog

| Image       | Parent               | Purpose                                                         |
|-------------|----------------------|-----------------------------------------------------------------|
| `runtime`   | `php:X.Y-fpm-trixie` | Shared layer: extensions, user, ini, entrypoint, imagick policy |
| `cli`       | `runtime`            | Artisan commands, migrations, one-off tasks                     |
| `fpm`       | `runtime`            | PHP-FPM behind Nginx/Caddy/Traefik                              |
| `builder`   | `runtime`            | Composer + Node build toolchain (not for production runtime)    |
| `queue`     | `cli`                | Laravel queue worker - [drains on SIGTERM](#queue---graceful-shutdown-and-the-one-setting-you-must-change), raise your grace period |
| `scheduler` | `cli`                | Laravel scheduler - [run exactly one replica](#scheduler---run-exactly-one-replica) |

## Configuration

Every image is configured through the environment; the entrypoint renders it
into `/usr/local/etc/php/conf.d/zz-laraoci.ini` at start, so any lexically later
mount still wins. The full table is §6.4 of the spec - what follows is what you
are most likely to need.

### `LARAOCI_DEFAULT_BINARY` - what a dash-first argument means

| Image                                  | Value     |
|----------------------------------------|-----------|
| `fpm`                                  | `php-fpm` |
| `cli`, `builder`, `queue`, `scheduler` | `php`     |

A **signal, not a knob.** Docker's official PHP images prepend `php-fpm` to any
command whose first argument starts with a dash, which is right for `fpm` and
wrong for everything else - `docker run cli -r 'echo 1;'` would start an FPM
master. This variable is how each image says which binary it means, and it is
read once by the LaraOCI entrypoint. Overriding it changes what a dash-invoked
command starts; it is documented so `docker inspect` answers the question
without anyone reading a Dockerfile.

### `LARAOCI_ALLOW_UNWRITABLE_CONFIG` — for a read-only root filesystem

The entrypoint renders `${PHP_INI_DIR}/conf.d/zz-laraoci.ini` at start, and that
file is how every `PHP_*` variable reaches PHP. It is pre-created owned by the
image's own uid, so a container run as a different user — `docker run --user
5000`, or a `securityContext.runAsUser` that does not match — **cannot write it
and will refuse to start**, rather than serving traffic on the build-time
defaults while ignoring everything you set.

If the build-time configuration is what you want — a read-only root filesystem,
say — set `LARAOCI_ALLOW_UNWRITABLE_CONFIG=1`. The container then starts and
logs which file it could not write. Your `PHP_*` overrides will not apply.

### Preload - opt-in opcache preloading

Every image ships a preload script at `/usr/local/share/laraoci/preload.php`. It
is **inert until you name it**, and naming it is necessary but not sufficient:

```bash
PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
PHP_OPCACHE_MEMORY_CONSUMPTION=320
```

**Preload is FPM-only by default.** The entrypoint writes the `opcache.preload`
directive only when the process it is about to start is `php-fpm`. opcache in a
CLI process is per-process - the shared segment is created at startup and
destroyed at exit - so on `cli` every `php artisan` call would compile the whole
framework and throw the result away.

**Long-lived CLI workers opt in with `LARAOCI_PRELOAD_FORCE=1`.** `queue` bakes
that flag, because a queue worker compiles once and then serves thousands of jobs
from the warm segment. It still does nothing until you name the script:

```yaml
services:
  queue:
    image: ghcr.io/laraoci/queue:8.4-trixie
    environment:
      PHP_OPCACHE_PRELOAD: /usr/local/share/laraoci/preload.php
      PHP_OPCACHE_MEMORY_CONSUMPTION: 320
```

**A wrapper command disables it.** The gate reads the *first argument* - `argv[0]`
- so anything that is not the PHP binary itself reads as "not an FPM process":

```bash
# preload ON
command: ["php-fpm"]
# preload OFF - argv[0] is `sh`, and the reason is logged at start:
#   laraoci: PHP_OPCACHE_PRELOAD is set but 'sh' is not an FPM process; ignoring
command: ["sh", "-c", "php-fpm"]
```

`command: ["sh","-c",…]` is the usual shape in a Kubernetes manifest, and an init
shim or a `wait-for-it`-style wrapper has the same effect. This is deliberate -
the gate fails closed rather than enabling a preload the process would throw away
- so if you need a wrapper, invoke the binary directly where you can, or set
  `LARAOCI_PRELOAD_FORCE=1` to state that this process is long-lived.


| Variable                   | Default                                                                        |
|----------------------------|--------------------------------------------------------------------------------|
| `PHP_OPCACHE_PRELOAD`      | *(unset)*                                                                      |
| `LARAOCI_PRELOAD_FORCE`    | *(unset; `1` on `queue`)*                                                      |
| `LARAOCI_PRELOAD_ROOT`     | `/var/www/html`                                                                |
| `LARAOCI_PRELOAD_PATHS`    | `vendor/laravel/framework/src/Illuminate,vendor/composer`                      |
| `LARAOCI_PRELOAD_IGNORE`   | `/tests/,/Tests/,/stubs/,/Stubs/,/Testing/,/migrations/,/resources/,/Console/` |

**Both list variables replace the list; neither appends.** To preload your own
classes as well, restate the defaults:

```bash
LARAOCI_PRELOAD_PATHS=vendor/laravel/framework/src/Illuminate,vendor/composer,app
```

`vendor/symfony` is deliberately absent from the default. Illuminate already
pulls in the Symfony components it uses; compiling the whole tree adds Mailer and
HttpKernel subtrees most applications never touch, for no hit-rate gain.

**`/Console/` is ignored by default, and that follows from the line above.**
Without the Symfony tree, `Illuminate\Console\Command` cannot resolve its parent
class, so it and the ~78 artisan commands extending it cannot be preloaded - they
only produce warnings. Console code is on no hot path either: `fpm` never touches
it while serving a request, and `queue` loads it once at worker start. Measured
on a Laravel 13 tree, ignoring it removes 131 of 176 startup warnings and 2.4 MB
of preload memory, and costs 80 preloaded classes that were doing nothing.

If your workload really is artisan-heavy and you want them back, restate the list
without that last entry:

```bash
LARAOCI_PRELOAD_IGNORE=/tests/,/Tests/,/stubs/,/Stubs/,/Testing/,/migrations/,/resources/
```

**You will still see about 45 `Can't preload unlinked class` warnings** at start
on a typical Laravel application, naming parents in `Symfony\…`, `Psr\…`,
`Monolog\…` and `GuzzleHttp\…`. That is **expected output, not a fault**: those
packages are outside the preload path set by design, so classes extending them
are compiled but not preloaded. Silencing them entirely would mean preloading
those trees too, at a memory cost the default deliberately declines.

**Four things to know before you turn it on:**

1. **It needs `vendor/` at container start.** With an empty root the script
   no-ops, logs zero and the container starts normally - silent, not fatal, by
   design. If you bind-mount your application, preload compiles whatever was
   there *when the container started*.
2. **It costs opcache memory.** Preloaded entries count against
   `opcache.memory_consumption`, which is why the pairing above raises it to
   320 MB. `opcache.max_accelerated_files` (20000 by default) must exceed the
   preloaded file count, or compilation stops part way and the startup line
   reports a number lower than reality.
3. **Changing anything preloaded requires a container restart.** Consistent with
   `opcache.validate_timestamps = 0`.
4. **Measure, do not guess.** The startup line tells you it ran:

   ```
   laraoci: preload enabled: /usr/local/share/laraoci/preload.php
   [31-Jul-2026 10:52:49 UTC] laraoci: preloaded 1325 files, skipped 362
   ```

   Both lines go to stderr. The first is the entrypoint's; the second is the
   script's, carrying the timestamp `error_log = /proc/self/fd/2` adds. If you
   set `log_errors = Off`, the second line disappears - the preload still runs.

   and `opcache_get_status()` tells you what it cost:

   ```bash
   docker compose exec queue php -r \
     'print_r(opcache_get_status()["preload_statistics"]);'
   ```

   That reports the memory consumed and the class/function/script counts. Tune
   against those numbers rather than against a target someone else measured.

You do not need `opcache.preload_user`. It is only required when the FPM master
runs as root, and LaraOCI runs as `laravel` throughout.

### `fpm` - pool sizing and shutdown

| Variable                          | Default   | Notes                                      |
|-----------------------------------|-----------|--------------------------------------------|
| `PHP_FPM_PM`                      | `dynamic` |                                            |
| `PHP_FPM_MAX_CHILDREN`            | `20`      |                                            |
| `PHP_FPM_START_SERVERS`           | `4`       |                                            |
| `PHP_FPM_MIN_SPARE_SERVERS`       | `2`       |                                            |
| `PHP_FPM_MAX_SPARE_SERVERS`       | `6`       |                                            |
| `PHP_FPM_MAX_REQUESTS`            | `500`     |                                            |
| `PHP_FPM_PROCESS_CONTROL_TIMEOUT` | `10s`     | the graceful-drain ceiling - see below     |

The entrypoint **refuses to start** if any of these is unset or empty, so a typo
is a loud failure rather than a blank directive php-fpm silently accepts.

`fpm` ships `STOPSIGNAL SIGQUIT`, which php-fpm reads as "finish in-flight
requests, then exit". That signal alone is not enough: with FPM's default
`process_control_timeout = 0` the master takes the graceful code path and then
exits without waiting for its busy children, truncating the response anyway.
`PHP_FPM_PROCESS_CONTROL_TIMEOUT` is the ceiling that makes it real - it is not a
delay, so an idle container still stops in ~0.2s.

**If your requests can run longer than 10s, raise this *and* your orchestrator's
grace period together** (`docker stop -t`, or `terminationGracePeriodSeconds`).
Raising only one silently keeps the shorter of the two.

You will also see these two lines at every start. They are **expected output**,
not a misconfiguration - the master runs as `laravel`, and a non-root master
cannot `setuid`. The directives are kept because they are the only thing
standing between `docker run --user 0` and workers running as `www-data`:

```
NOTICE: [pool www] 'user' directive is ignored when FPM is not running as root
NOTICE: [pool www] 'group' directive is ignored when FPM is not running as root
```

### `fpm` - healthcheck and endpoints

The image ships its own `HEALTHCHECK`; you do not need to write one.

    HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3

It speaks FastCGI straight to the pool with `cgi-fcgi`, so it exercises the same
socket your web server uses rather than a side channel. Two pool-internal
endpoints back it:

| Endpoint      | Purpose                                              |
|---------------|------------------------------------------------------|
| `/fpm-ping`   | returns `pong` - what the healthcheck asks for       |
| `/fpm-status` | FPM's own status page, for operators                 |

Both are answered by FPM itself and never reach PHP, so an application route
cannot shadow them, and they keep working when your application does not. See
[Security notes](#security-notes) before routing to `/fpm-status`.

In Compose, `condition: service_healthy` is what turns this into a real gate:

```yaml
services:
  fpm:
    image: ghcr.io/laraoci/fpm:8.4-trixie
  nginx:
    depends_on:
      fpm:
        condition: service_healthy
```

### `builder` - mountable cache paths

| Variable           | Default                   |
|--------------------|---------------------------|
| `COMPOSER_HOME`    | `/home/laravel/.composer` |
| `NPM_CONFIG_CACHE` | `/home/laravel/.npm`      |

Both are part of the contract, so you can mount BuildKit caches at them. Both are
owned `1000:1000`, and the image runs as `laravel`, so pass the ids - a cache
mount that only root can write is a silent no-op:

```dockerfile
FROM ghcr.io/laraoci/builder:8.4-trixie AS build
COPY composer.json composer.lock ./
RUN --mount=type=cache,target=/home/laravel/.composer,uid=1000,gid=1000 \
    composer install --no-dev --no-scripts --prefer-dist --no-interaction
COPY . .
RUN --mount=type=cache,target=/home/laravel/.npm,uid=1000,gid=1000 \
    composer dump-autoload --optimize --classmap-authoritative \
 && npm ci && npm run build

FROM ghcr.io/laraoci/fpm:8.4-trixie
COPY --from=build --chown=laravel:laravel /var/www/html /var/www/html
```

**`builder` is not a production runtime.** It carries a package manager, a VCS
client and a JavaScript runtime; use it in a build stage and copy the result
into `fpm`, `cli`, `queue` or `scheduler`.

**Limitation - no native-module toolchain.** npm packages that compile through
`node-gyp` will fail: `python3` is not installed. The C/C++ toolchain inherited
from the upstream PHP image (`make`, `gcc`, `g++`) is present but is not
sufficient on its own. Packages shipping prebuilt binaries are unaffected, which
covers the ordinary Laravel front-end stack. If you need `node-gyp`, add
`apt-get install -y python3` to your own build stage.

### `queue` - graceful shutdown, and the one setting you must change

The image ships:

```
CMD ["php","artisan","queue:work","--no-interaction","--tries=3","--max-time=3600","--rest=0.1"]
```

| Flag              | Why                                                                        |
|-------------------|----------------------------------------------------------------------------|
| `--tries=3`       | A poison job reaches `failed_jobs` instead of looping forever              |
| `--max-time=3600` | Bounds worker lifetime so leaks and stale state never accumulate           |
| `--rest=0.1`      | Yields the CPU for 100 ms between jobs                                     |
| `--no-interaction`| A prompt in a container is a hung worker                                   |

`queue:work` traps `SIGTERM` through `pcntl` and finishes the job in hand before
exiting. The image carries `STOPSIGNAL SIGTERM`, `pcntl`/`posix` are compiled in,
and `tini` is PID 1 forwarding the signal - so `docker stop` **drains** rather
than truncates.

> **⚠️ Your orchestrator's grace period must exceed your job timeout.**
> Laravel's default job timeout is **60 s**. Docker's default stop grace is
> **10 s**. Against those defaults every rolling deploy kills in-flight jobs
> after ten seconds, no matter how correct this image is. **The image cannot fix
> this** - it does not know how long your jobs run.

```bash
docker stop --timeout 120 my-worker
```

```yaml
# compose
services:
  queue:
    image: ghcr.io/laraoci/queue:8.4-trixie
    stop_grace_period: 120s
```

```yaml
# kubernetes
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 120
```

Pick a number above your longest job's timeout, and raise both together if you
change either. `--timeout` is deliberately not set on the shipped `CMD`, so
Laravel's 60 s default applies until you set one.

**What getting it wrong looks like.** A 20 s job against a 2 s grace, which is the
same shape as a 60 s job against Docker's 10 s default:

```
$ docker stop --timeout 2 worker      # returns after 2.4s
$ docker inspect worker --format '{{.State.ExitCode}}'
137                                    # 128+9 = SIGKILL
```

The job wrote its start marker and never its end. Exit **137** on a worker is the
signature of this specific mistake - the grace period expiring on a container that
was still working. A drained worker exits **0**, and `docker stop` returns in the
job's remaining time rather than at the ceiling.

**No `HEALTHCHECK`, deliberately.** A queue worker has no meaningful synchronous
health signal, and a naive check is worse than none - it reports healthy while the
queue backs up behind a wedged worker. Monitor the queue instead:

```bash
php artisan queue:monitor default:100     # on a schedule
```

or run Horizon, which is built for it.

### `scheduler` - run exactly one replica

The image ships `CMD ["php","artisan","schedule:work","--no-interaction"]`: one
foreground process that stays alive, dispatches your due tasks on each minute
boundary, and logs to stdout like every other container. No cron daemon, no log
files, no process tree to reap.

> **⚠️ Exactly one replica.** Two scheduler containers fire every task twice.
> There is no image-level guard against this and there cannot be - an image
> cannot know how many copies of itself are running.

```yaml
# compose
services:
  scheduler:
    image: ghcr.io/laraoci/scheduler:8.4-trixie
    deploy:
      replicas: 1
```

```yaml
# kubernetes
spec:
  replicas: 1
  strategy:
    type: Recreate    # never two schedulers overlapping during a rollout
```

`Recreate` matters as much as `replicas: 1`: the default `RollingUpdate` starts
the new pod before terminating the old one, so a rollout briefly runs two
schedulers - and a task due in that window fires twice.

**If you need the scheduler to survive a node failure**, that is *application*
configuration, not image configuration. Give the tasks `withoutOverlapping()` and
point the cache at a **shared** store (Redis, database) so the lock is visible to
every replica:

```php
Schedule::command('reports:build')->hourly()->withoutOverlapping();
```

With the default per-container cache store each scheduler takes its own local
lock and the guard does nothing.

## Repository layout

- `config/images.yml` - the single source of truth; CI derives the build matrix from it.
- `bin/` - `matrix.sh`, `affected.sh`, `build-chain.sh`, `size-check.sh`, `structure-test.sh`, `fetch-tools.sh`, and the container entrypoint.
- `images/` - per-image Dockerfiles.
- `tests/` - bats unit tests, structure tests, the smoke harness, fixtures.
- `.github/workflows/` - `lint`, `build` (reusable), `pr`, `smoke`.

## Local development

The Makefile is convenience only - every recipe is a single delegation to a
script under `bin/` or to an already-pinned tool, and CI calls those scripts
directly rather than going through `make`. It saves typing; it is never the
source of truth.

    make                # list every target
    make tools          # fetch the pinned tools (see tools.env for the current set)

    make test           # unit suite, under the pinned bats
    make lint           # shellcheck every tracked shell script
    make fmt            # shell formatting check  (make fmt-fix applies it)
    make dockerfiles    # hadolint every Dockerfile
    make actions        # actionlint the workflows

    make matrix         # the full CI build matrix as JSON
    make sizes          # image sizes against their budgets (advisory)
    make structure IMAGE=runtime          # add PHP=8.5 for a non-default version

`make structure` tests the image tag `bin/build-chain.sh` produces, so build it
first; without `PHP=` it uses whichever version carries `default: true` in
`config/images.yml`.

Run `make tools` first: the linting targets call the cached binaries under
`.cache/tools/bin`, so local runs use the same pinned versions as CI. Everything
you should have green before pushing:

    make hooks          # prints the sequence, so you can paste it

Images below `runtime` begin `FROM ghcr.io/laraoci/runtime:…`, a reference that
exists in no registry until M4 publishes one. Build an image together with every
ancestor it stands on:

    bin/build-chain.sh --image fpm --php 8.4

The end-to-end suite builds `cli`, `fpm` and `builder`, seeds a Laravel fixture
into a named volume, brings up `fpm` behind nginx, and tears the whole stack down
unconditionally - including on failure and on Ctrl-C:

    tests/smoke/run.sh --php 8.4                   # add --keep to inspect the stack

## Supply chain

Every published image carries an SPDX SBOM, SLSA provenance (`mode=max`), a
Cosign keyless signature, and the full OCI label set. All four are verifiable
from a terminal with nothing installed but `cosign`, `docker` and `jq`.

**Every command below was executed against a real image this pipeline published
before it was written here** - on a staging namespace, by the same workflows that
publish production. A verify command that has never been run is worse than none:
it teaches you a check that always fails, and you stop running checks. Substitute
the tag you are actually pulling.

### Verify the signature

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/laraoci/runtime/\.github/workflows/merge\.yml@refs/tags/v' \
  ghcr.io/laraoci/runtime:8.4-trixie-20260811 | jq .
```

The identity names **`merge.yml`**, not `release.yml`, and that is correct rather
than a typo: Fulcio takes the certificate subject from the OIDC
`job_workflow_ref` claim, which is the *reusable* workflow that ran `cosign
sign`. Verified both ways - the `merge.yml` form succeeds and the `release.yml`
form exits 1.

The regexp is anchored on `refs/tags/v` so only tag-built releases verify. An
image built by a manual `workflow_dispatch` carries a branch ref instead and will
**not** satisfy this command, deliberately: production images come from tags.

That anchor is the one element here not yet exercised end to end. The signature,
the issuer and the `merge.yml` subject were all verified against a real signature
on a `workflow_dispatch` run, whose subject ends `@refs/heads/main`; the
`refs/tags/v` form first runs for real on the first tagged release. `merge.yml`
verifies its own signature in-job on every release, so a wrong subject fails in
CI rather than in your terminal.

Signing is recursive, so a per-platform digest is signed too - the same command
against `runtime@sha256:<arch-specific digest>` verifies.

### Inspect the SBOM

```bash
docker buildx imagetools inspect ghcr.io/laraoci/runtime:8.4-trixie-20260811 \
  --format '{{ json (index .SBOM "linux/arm64").SPDX }}' | jq '.packages | length'
```

Drop the `index …` wrapper for a single-platform reference. The predicate is
`https://spdx.dev/Document`. Both architectures carry their own SBOM.

### Inspect the build provenance

```bash
docker buildx imagetools inspect ghcr.io/laraoci/runtime:8.4-trixie-20260811 \
  --format '{{ json (index .Provenance "linux/amd64").SLSA }}' \
  | jq '.buildDefinition.buildType,
        .buildDefinition.externalParameters.configSource,
        .runDetails.builder.id,
        (.buildDefinition.resolvedDependencies | length)'
```

These are **SLSA v1** paths. The older v0.2 shape (`.buildType`,
`.invocation.configSource`) does not error against what BuildKit attaches - it
prints `null` and reads as success, which is the worst possible outcome for a
verification command.

`runDetails.builder.id` is the workflow run that produced the image. A non-empty
`resolvedDependencies` is the `mode=max` marker: the attestation carries the
Dockerfile, the build arguments and the layer source maps, not just a summary.

### Confirm both architectures are present

```bash
docker buildx imagetools inspect ghcr.io/laraoci/runtime:8.4-trixie-20260811 \
  --format '{{ json .Manifest }}' \
  | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"'
```

`unknown/unknown` entries in that output are the SBOM and provenance manifests,
not a broken image. Expect one per real platform.

## Choosing a tag

| Tag form      | Example                     | Mutability    | Use                    |
|---------------|-----------------------------|---------------|------------------------|
| PHP minor     | `:8.4`                      | Rolling       | Dev, non-critical      |
| PHP + Debian  | `:8.4-trixie`               | Rolling       | Explicit OS pin        |
| Dated         | `:8.4-trixie-20260811`      | **Immutable** | **Production**         |
| Patch + dated | `:8.4.10-trixie-20260811`   | **Immutable** | Strict pinning         |
| Digest        | `@sha256:…`                 | **Immutable** | Supply-chain-strict    |
| `:latest`     |                             | Rolling       | Default PHP version only |

**Use a dated tag or a digest in production.** Rolling tags are repointed by
every release and by the weekly rebuild; that is what makes them useful for
development and unsuitable for a deployment you want to be able to reproduce.

A dated tag is never overwritten. A same-day rebuild publishes a counter instead:
`:8.4-trixie-20260811-2`, then `-3`. So a dated tag you have pinned cannot change
underneath you, and a rebuild is always visible as a new reference.

Keep them current automatically:

```json
// renovate.json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "packageRules": [
    {
      "matchDatasources": ["docker"],
      "matchPackageNames": ["ghcr.io/laraoci/**"],
      "versioning": "regex:^(?<major>\\d+)\\.(?<minor>\\d+)-(?<compatibility>\\w+)-(?<patch>\\d+)(?:-(?<build>\\d+))?$",
      "pinDigests": true
    }
  ]
}
```

The trailing `(?:-(?<build>\d+))?` is load-bearing: without it the pattern misses
every same-day rebuild, and `-20260811-2` is a reference this project really does
publish. `compatibility` holds the Debian suite, so Renovate will not offer you a
`bookworm` image as an upgrade from a `trixie` one. Rolling tags and the
patch+dated form deliberately do not match - the first should not be bumped by a
bot, and the second changes on PHP patch releases as well as dates, which is a
different scheme.

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
```

Dependabot updates the tag in your `Dockerfile` or compose file; Renovate can
additionally pin the digest beside it, which is the strongest form and the one
the signature and SBOM commands above are keyed to.

## Security notes

### `/fpm-status` is enabled, and your web server must not route to it

`fpm` ships `pm.status_path = /fpm-status`. FPM answers it **itself**, matching
on `SCRIPT_NAME` before the request reaches PHP — so it is unaffected by your
application's routes, and your application cannot shadow, protect or disable it.

It reports pool internals: process manager, active and idle children, listen
queue depth, slow-request count. With `?full` it adds the URI, script and
runtime of every request in flight.

The standard Laravel nginx configuration never exposes it: every dynamic request
arrives as `SCRIPT_NAME=/index.php`, so FPM never sees `/fpm-status`. You expose
it by forwarding a raw path — a `location ~ \.php$` block combined with a
`try_files` that passes the original URI, or a broadened Caddy `php_fastcgi`
matcher. **Check your web server config; the failure is silent and on your
side.**

`/fpm-ping` is different and safe to leave reachable: it returns the fixed
string `pong` and discloses nothing. The image's own `HEALTHCHECK` depends on it.

### The images run as uid 1000 and expect to write their own config

See [`LARAOCI_ALLOW_UNWRITABLE_CONFIG`](#laraoci_allow_unwritable_config--for-a-read-only-root-filesystem).
A container run as another uid refuses to start rather than silently ignoring
your `PHP_*` settings.

### `builder` is not a production runtime

It carries a package manager, a VCS client and a JavaScript runtime. Use it in a
build stage and copy the result into `fpm`, `cli`, `queue` or `scheduler`.

## License

[MIT](LICENSE.md).
