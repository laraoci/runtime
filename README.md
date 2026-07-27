# LaraOCI

Production-ready OCI images for Laravel applications: secure defaults, a single
shared runtime layer, and a maintained security posture. You bring `vendor/` and
your code; LaraOCI brings a correct PHP runtime, signal handling, logging, and
weekly rebuilds.

> **Status:** pre-release. M0 (foundations) builds the config-driven build
> pipeline; images arrive in M1+. See `docs/laraoci-Spec.md`.

## Image catalog

| Image       | Parent               | Purpose                                                         |
|-------------|----------------------|-----------------------------------------------------------------|
| `runtime`   | `php:X.Y-fpm-trixie` | Shared layer: extensions, user, ini, entrypoint, imagick policy |
| `cli`       | `runtime`            | Artisan commands, migrations, one-off tasks                     |
| `fpm`       | `runtime`            | PHP-FPM behind Nginx/Caddy/Traefik                              |
| `builder`   | `runtime`            | Composer + Node build toolchain (not for production runtime)    |
| `queue`     | `cli`                | Laravel queue worker                                            |
| `scheduler` | `cli`                | Laravel scheduler                                               |

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

[MIT](LICENSE.md).
