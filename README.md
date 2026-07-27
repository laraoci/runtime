# LaraOCI

Production-ready OCI images for Laravel applications: secure defaults, a single
shared runtime layer, and a maintained security posture. You bring `vendor/` and
your code; LaraOCI brings a correct PHP runtime, signal handling, logging, and
weekly rebuilds.

> **Status:** pre-release. M0 (foundations) and M1 (the shared `runtime` layer)
> are complete; `cli`, `fpm` and `builder` arrive in M2, `queue` and `scheduler`
> in M3, and publishing, signing and scanning in M4. See `docs/laraoci-Spec.md`.

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
- `bin/` - `matrix.sh`, `affected.sh`, `size-check.sh`, `structure-test.sh`, `fetch-tool.sh`, and the container entrypoint.
- `images/` - per-image Dockerfiles.
- `tests/` - bats unit tests, structure tests, smoke tests, fixtures.
- `.github/workflows/` - `lint`, `build` (reusable), `pr`.

## Local development

    tests/bats/bin/bats tests/unit                 # unit tests (needs mikefarah/yq v4 + jq)
    shellcheck -S warning $(git ls-files '*.sh')
    shfmt -d -i 2 -ci $(git ls-files '*.sh')
    bin/matrix.sh | jq '.include | length'         # 36

## License

[MIT](LICENSE.md).
