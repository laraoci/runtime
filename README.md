# LaraOCI

Production-ready OCI images for Laravel applications: secure defaults, a single
shared runtime layer, and a maintained security posture. You bring `vendor/` and
your code; LaraOCI brings a correct PHP runtime, signal handling, logging, and
weekly rebuilds.

> **Status:** pre-release. M0 (foundations), M1 (the shared `runtime` layer) and
> M2 (`cli`, `fpm`, `builder`) are complete; `queue` and `scheduler` arrive in
> M3, and publishing, signing and scanning in M4. **Nothing is published yet** -
> the image references below are what M4 will push; until then images are built
> locally with `bin/build-chain.sh`. See `docs/laraoci-Spec.md`.

## Image catalog

| Image       | Parent               | Purpose                                                         |
|-------------|----------------------|-----------------------------------------------------------------|
| `runtime`   | `php:X.Y-fpm-trixie` | Shared layer: extensions, user, ini, entrypoint, imagick policy |
| `cli`       | `runtime`            | Artisan commands, migrations, one-off tasks                     |
| `fpm`       | `runtime`            | PHP-FPM behind Nginx/Caddy/Traefik                              |
| `builder`   | `runtime`            | Composer + Node build toolchain (not for production runtime)    |
| `queue`     | `cli`                | Laravel queue worker                                            |
| `scheduler` | `cli`                | Laravel scheduler                                               |

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
cannot shadow them, and they keep working when your application does not. Neither
is exposed through your web server unless you route to it deliberately - and
`/fpm-status` should not be public.

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
    make tools          # fetch the pinned tools (shfmt, yq, hadolint, actionlint, bats)

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

## License

[MIT](LICENSE.md).
