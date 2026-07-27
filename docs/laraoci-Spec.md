# LaraOCI - Architecture & Implementation Specification

**Status:** Draft v2 · Spec-first, pre-implementation
**Scope:** Image catalog, runtime contract, build pipeline, supply chain, release policy

---

## 1. Vision

LaraOCI provides production-ready OCI images for Laravel applications that are secure, lightweight, well-maintained, and easy to deploy.

Instead of every Laravel project maintaining its own Dockerfiles, LaraOCI publishes a curated set of images that encode Laravel and container best practices. Deploying a Laravel application should mean choosing the right image and supplying application code.

**The contract with consumers:** *you bring `vendor/` and your code; we bring a correct PHP runtime, correct signal handling, correct logging, and a maintained security posture.*

---

## 2. Design Principles

### 2.1 Production first

Secure defaults, minimal attack surface, non-root execution, tuned PHP configuration. Nothing in a runtime image exists unless a production Laravel workload needs it.

### 2.2 Reusable layers

All images descend from a single shared runtime layer. Divergence is limited to the process an image runs and the tools that process requires.

```
                    php:X.Y-fpm-trixie       (official upstream)
                              │
                              ▼
                     laraoci/runtime          (shared layer, published)
        ┌─────────────┬───────┴───────┬───────────────┐
        │             │               │               │
        ▼             ▼               ▼               ▼
  laraoci/cli   laraoci/fpm    laraoci/builder   (future variants)
        │
   ┌────┴─────┐
   ▼          ▼
 queue    scheduler          (CMD-only derivatives of cli)
```

> **Correction to the original draft:** FPM branches from `runtime`, not from `queue`. FPM is a sibling of CLI, not a descendant of a worker image.

### 2.3 Configuration over duplication

PHP versions, Debian releases, extension sets, and image types live in `config/images.yml`. CI derives the build matrix from that file. Adding a PHP version is a one-file change; no workflow edits.

### 2.4 Immutable, not "reproducible"

`apt-get` against moving mirrors cannot produce bit-identical images. LaraOCI does not claim bit reproducibility. It claims **immutability and verifiability**: every published artifact is addressable by digest, carries an SBOM and build provenance, and is signed.

---

## 3. Decision Register

| #       | Decision                                                                                 | Rationale                                                                                                  |
|---------|------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| D1      | FPM inherits from `runtime`, not `queue`                                                 | FPM and CLI are siblings; the original graph was a transcription error                                     |
| D2      | The shared layer is named `runtime` and is **published**                                 | Users with unusual needs extend rather than fork; `base` read as internal-only                             |
| D3      | A `builder` image ships in v1, **multi-arch**                                            | `vendor/` must come from somewhere; ARM matters for Apple Silicon local builds (revised - see D3a)         |
| D4      | `queue` and `scheduler` ship as `FROM cli` + `CMD` only                                  | Near-zero marginal cost, room to diverge later                                                             |
| D5      | **One Debian release across the entire matrix** - `trixie`                               | Collapses the OS axis to a constant; see §3.1                                                              |
| D6      | Composer is **absent** from `cli`, `fpm`, `queue`, `scheduler`                           | Attack surface; those images run application code, not dependency resolution                               |
| D7      | Node/Vite tooling lives only in `builder`                                                | Same reasoning as D6                                                                                       |
| D8      | Fixed UID/GID `1000:1000`, user `laravel`, across all images                             | Shared `storage/` volumes; mismatched ownership is the #1 support burden                                   |
| D9      | `tini` as init in every image                                                            | Zombie reaping and signal forwarding, independent of `--init`                                              |
| D10     | Scheduler uses `schedule:work`, not cron                                                 | Container-native, single foreground process, logs to stdout                                                |
| D11     | JIT disabled by default                                                                  | Neutral-to-negative for typical FPM/Laravel workloads                                                      |
| D12     | Extensions installed via `docker-php-extension-installer`                                | Large maintenance saving over hand-rolled builds                                                           |
| **D13** | `imagick` included in `runtime`, with a **hardened `policy.xml`** and **no Ghostscript** | Broad demand; the delegate/coder denylist removes the entire ImageTragick-class attack surface (§3.2)      |
| **D14** | An opt-in **preload script** ships at a fixed path, disabled by default                  | Real gains for FPM; too failure-prone to enable blindly                                                    |
| **D15** | PHP **8.3, 8.4, 8.5** all `supported`                                                    | No `preview` tier at launch                                                                                |
| **D16** | **FrankenPHP** is the first post-v1 variant, and is permitted a **second root layer**    | It is a SAPI, not a bolted-on web server (§3.3)                                                            |
| **D17** | CI enforces a **per-image size budget**                                                  | Makes "lightweight" a testable claim rather than an aspiration                                             |
| **D18** | `runtime` derives from the **`-fpm` upstream variant**, not `-cli`                       | The only way the single-root graph is actually achievable; the fpm variant ships the CLI binary too (§3.4) |
| **D19** | `install-php-extensions` is pinned by **digest**, not by tag                             | Determinism in the one layer that decides the whole extension surface; Renovate keeps it current (§2.4)    |
| **D20** | The LaraOCI entrypoint **chains** `docker-php-entrypoint` rather than replacing it       | Preserves upstream's leading-`-` argument fixup for free and reimplements nothing (§6.2)                   |
| **D21** | `procps` is **not** installed in any image                                               | One process per container makes `ps` near-useless; `kubectl debug` covers incidents (§7.1)                 |
| **D22** | Preload is gated on the **SAPI** by the entrypoint, written to a separate ini            | CLI opcache is per-process, so preload taxes every `php artisan` call and persists nothing (§7.7)          |

### 3.4 Why `runtime` uses the `-fpm` upstream variant (D18)

The v2 draft said `fpm` would "install the FPM SAPI on top of `runtime`" so that all images share one root. **That is not implementable.** The official `php:` images compile PHP from source into `/usr/local`; there is no Debian package that adds `php-fpm` to such a build. Getting FPM onto a `-cli` base would mean recompiling PHP - an enormous and permanent maintenance commitment.

The resolution is to invert it. Inspecting `docker-library/php`, the `cli` and `fpm` Dockerfiles are the same build with different `configure` flags: `fpm` adds `--enable-fpm`, `--with-fpm-user/group`, and `--disable-cgi`, and **nothing disables the CLI SAPI**. So `php:X-fpm-trixie` ships *both* `/usr/local/sbin/php-fpm` and `/usr/local/bin/php`.

Basing `runtime` on the `-fpm` variant therefore gives a genuinely single-rooted graph with real shared layers, rather than a shared-source fiction. `fpm` supplies a pool config and a command; `cli` supplies a command.

Costs, all small and stated:

- `cli`, `queue`, `scheduler`, and `builder` carry the unused `php-fpm` binary - single-digit megabytes.
- The `fpm` variant builds with `--disable-phpdbg` and without `--enable-embed`, both of which the `cli` variant has. phpdbg is rarely used in containers; `--enable-embed` matters only for embedding SAPIs, and FrankenPHP has its own root anyway (§3.3). If either becomes load-bearing, the graph splits - but not before evidence.

### 3.1 Why one Debian for everything (D5, revising the earlier per-version pin)

The v1 draft pinned Debian per PHP version, which would have put 8.3/8.4 on bookworm and 8.5 on trixie. Supporting all three versions makes that a two-OS matrix carrying two sets of package CVEs, two glibc versions, and two ImageMagick config paths - for no consumer-visible benefit.

Bookworm's regular security support window has closed; it is now maintained by the Debian LTS team on narrower terms. A project publishing its *first* images should not launch on an OS already in LTS. Standardising on trixie collapses the axis to a constant.

The `debian` key stays in `config/images.yml` per PHP version. It is a transition mechanism, not a product axis - when trixie ages out, versions migrate individually rather than in a flag day.

**Verified.** `docker-library/php` publishes `trixie/cli`, `trixie/fpm`, `trixie/apache`, and `trixie/zts` for **every** currently-built version - 8.2, 8.3, 8.4, and 8.5 - alongside the bookworm and Alpine variants. There is no fallback case; the single-OS matrix holds.

Current upstream patch levels at time of writing: 8.3.32, 8.4.23, 8.5.8. An 8.6 alpha is already being built with full trixie coverage, so the 8.6 GA (expected late 2026) will slot into `config/images.yml` as a one-line addition.

**8.2 is deliberately excluded** despite still being built upstream. Its security window closes at the end of 2026; adding it now means adding twelve build legs and deprecating them within about five months.

### 3.2 The imagick trade (D13)

Including imagick is a real cost, stated plainly:

- **Size:** ImageMagick core plus delegates adds an estimated **70–100 MB**. Much of the delegate set (libjpeg, libpng, libwebp, libfreetype) is already present for `gd`, so the net figure is the number to measure, not the package total. **Measured and frozen in M1:** `runtime` compresses to 227.6 / 230.5 / 232.6 MB on 8.3 / 8.4 / 8.5, and `size_budgets.runtime` is committed at **260 MB** (max + 10% headroom, rounded to 5). See `docs/size-report-m1.md` for the method, the tool, and the host arch; growth is monotonic with the PHP minor, so 8.5 sets the budget.
- **CVE surface:** ImageMagick has the heaviest vulnerability history of anything in the image.

Both are mitigated rather than accepted:

**No Ghostscript - but it must be actively removed, not merely not-requested.** ImageMagick's PDF, PS, and EPS handling shells out to Ghostscript, the vector for nearly every ImageMagick RCE of the last decade.

Two facts make this a build step rather than an omission:

1. `install-php-extensions imagick` **installs `ghostscript` unconditionally on Debian** and marks it persistent. `--no-install-recommends` does not prevent this; the installer names the package directly.
2. Ghostscript is only a **Recommends** of `libmagickcore-7.q16-*`, never a Depends. Nothing breaks when it goes.

So the runtime image purges it explicitly after the extension install. The purge is a hard step with no `|| true`, and a structure test asserts `gs` is absent, so a future installer change that reorders things fails the build loudly instead of silently reintroducing the interpreter.

**`--auto-remove` does not reclaim the tree - M1 disproved that.** The installer marks everything it pulls in as *manually* installed, and `--auto-remove` only reclaims *auto*-marked packages: `apt-get purge -y --auto-remove ghostscript` on its own frees **187 kB** and leaves the rest in place. Every package must be named: `ghostscript`, `libgs10`, `libgs10-common`, `libgs-common`, `poppler-data` - **38.1 MB installed**, measured. `fonts-urw-base35` is deliberately **retained**, contrary to the earlier wording here: it is a Recommends of `libmagickcore-7.q16-10`, i.e. ImageMagick's standard PostScript-35 font set, not Ghostscript baggage, and removing it silently breaks text annotation for anyone who does not name a font explicitly.

The purge and its assertions live in the **same `RUN`** as the extension install. Docker layers are additive, so a purge in a later instruction removes the files from the final filesystem while leaving their bytes in the earlier layer's tarball - an image that passes `command -v gs` and still ships the interpreter.

PDF rasterisation is explicitly out of scope (§14). An application that needs it installs Ghostscript in its own layer, consciously.

**Hardened `policy.xml`,** shipped at build time, denying all delegates, the Ghostscript-adjacent coders, the network coders, and indirect-read paths:

```xml
<policymap>
  <policy domain="delegate" rights="none" pattern="*"/>
  <policy domain="coder" rights="none" pattern="{PS,PS2,PS3,EPS,PDF,XPS}"/>
  <policy domain="coder" rights="none" pattern="{MSL,MVG,MAGICK,TEXT,SHOW,WIN,PLT}"/>
  <policy domain="coder" rights="none" pattern="{URL,HTTP,HTTPS,FTP}"/>
  <policy domain="path"  rights="none" pattern="@*"/>
  <policy domain="resource" name="memory" value="256MiB"/>
  <policy domain="resource" name="map"    value="512MiB"/>
  <policy domain="resource" name="width"  value="16KP"/>
  <policy domain="resource" name="height" value="16KP"/>
  <policy domain="resource" name="area"   value="128MP"/>
  <policy domain="resource" name="disk"   value="1GiB"/>
  <policy domain="resource" name="time"   value="60"/>
  <policy domain="resource" name="thread" value="1"/>
</policymap>
```

`domain="path" pattern="@*"` blocks ImageMagick's indirect-read syntax, which is how a crafted filename turns into an arbitrary file read.

`thread value="1"` plus `MAGICK_THREAD_LIMIT=1` in the environment is a production correctness fix, not just a security one: ImageMagick's OpenMP pool spawns per process, so N FPM children each opening a thread pool will thrash a CPU-limited container. Consumers doing heavy batch work in `queue` can raise it.

**Trixie is ImageMagick 7, confirmed.** `install-php-extensions` branches on the Debian major version and pulls `libmagickwand-7.q16-*` / `libmagickcore-7.q16-*-extra` (plus `libheif-plugin-aomenc`) on 13+, versus the `6.q16` packages on bookworm. The policy therefore lands at `/etc/ImageMagick-7/policy.xml`. The build still writes to whichever directory exists, so a future suite bump doesn't silently drop the policy on the floor.

**Consequence for consumers:** LaraOCI images link imagick against **ImageMagick 7**, not 6. Anyone migrating from a bookworm-based image is changing major ImageMagick versions at the same time - a handful of Imagick API behaviours differ between IM6 and IM7. This belongs in the README's migration notes, not buried in a changelog.

**The image contains no ImageMagick CLI tools.** Only the libraries are installed, so `identify`, `convert`, and `magick` do not exist. Policy assertions must go through PHP (§10.1), not through `identify -list policy`.

**The `-extra` codec package is unavoidable** via this installer path. It brings DjVu, WMF, OpenEXR, and RAW decoders - more parser surface than a Laravel app typically needs. The delegate denial blunts the worst of it, and the weekly rebuild (§9.3) is the ongoing control.

**The size half of that argument does not survive measurement.** M1 built the image twice, identical but for the package, and the delta was **0.08 MB compressed**: `libmagickcore-7.q16-10-extra` is a 295 KB shim of coder modules. The decoders arrive as its dependencies and survive `--auto-remove` for the same reason the Ghostscript tree did, so reclaiming them means naming them - `libopenexr-3-1-30`, `libdjvulibre21`, `libdjvulibre-text`, `libwmflite-0.2-7`, **8.7 MB installed** between them. A wider sweep that also takes decoders owned by ImageMagick *core* (`libraw23t64`, `libheif1`, `libopenjp2-7`, the libheif plugins) reaches 13.5 MB installed, but those are not `-extra`'s to give back. The 70–100 MB imagick costs is ImageMagick proper. Hand-rolling the apt install to skip `-extra` is therefore **not** a size escape hatch; if it happens it is a parser-surface argument.

**Escape hatch if size becomes a complaint:** publish `-slim` variants without imagick rather than reversing the default. That reopens the matrix, so it happens on evidence, not speculation - and per the numbers above, `-slim` (LOCI-056) must be argued on CVE and parser surface, with those figures stated so nobody expects a size win.

### 3.3 Why FrankenPHP gets a second root (D16)

FrankenPHP embeds a Caddy web server, which reads as a direct violation of §14's "no opinionated infrastructure." The distinction that resolves it: LaraOCI would not be adding a web server *alongside* PHP - in FrankenPHP, the server **is** the SAPI, the same way `php-fpm` is a SAPI. Shipping `laraoci/fpm` without shipping Nginx is consistent; shipping `laraoci/frankenphp` is the same shape.

The genuine architectural cost is different: FrankenPHP is distributed as `dunglas/frankenphp`, not as a `php:` variant, and it embeds its own PHP build with its own extension set. It therefore **cannot descend from `laraoci/runtime`** without either compiling FrankenPHP from source (a large, ongoing maintenance commitment) or duplicating the extension layer.

This breaks §2.2 for exactly one image. The decision is to accept the second root and document it, rather than distort the rest of the design to preserve a clean graph. It is deferred to post-v1 and needs its own design note covering worker mode, the Octane driver, `clear_env` equivalence, and how the runtime contract of §6 is upheld on a base LaraOCI does not control.

---

## 4. Image Catalog

| Image       | Parent               | Purpose                                                         | Published  |
|-------------|----------------------|-----------------------------------------------------------------|------------|
| `runtime`   | `php:X.Y-fpm-trixie` | Shared layer: extensions, user, ini, entrypoint, imagick policy | Yes        |
| `cli`       | `runtime`            | Artisan commands, one-off tasks, migrations                     | Yes        |
| `fpm`       | `runtime`            | PHP-FPM behind Nginx/Caddy/Traefik                              | Yes        |
| `builder`   | `runtime`            | Composer + Node + build toolchain for multi-stage builds        | Yes        |
| `queue`     | `cli`                | Laravel queue worker                                            | Yes        |
| `scheduler` | `cli`                | Laravel scheduler                                               | Yes        |

`runtime` uses the **`fpm`** upstream variant, which ships the CLI binary as well - see D18/§3.4 for why this is the only single-root arrangement that actually works.

### Post-v1 variants

FrankenPHP (first, per D16), then Octane/Swoole, RoadRunner, Horizon, Reverb, and development variants with Xdebug.

Each must justify itself against D4: if it is `cli` plus a `CMD`, it is a thin derivative, not an image.

---

## 5. Configuration File

`config/images.yml` is the single source of truth. CI reads it with `yq` and emits a JSON matrix.

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
  "8.3":
    status: supported
  "8.4":
    status: supported
    default: true
  "8.5":
    status: supported

extensions:
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

size_budgets:          # compressed, MB - enforced by D17
  runtime: 260         # MEASURED in M1 - the 220 shown in the v2 draft was already too low
  cli: 225
  fpm: 235
  builder: 500
  queue: 225
  scheduler: 225

images:
  runtime:
    dockerfile: images/runtime/Dockerfile
  cli:
    parent: runtime
  fpm:
    parent: runtime
    exposes: [9000]
  builder:
    parent: runtime
  queue:
    parent: cli
  scheduler:
    parent: cli
```

### Schema rules

- `php.<version>.status` ∈ `supported` | `deprecated`. Only `supported` is built; `deprecated` keeps existing tags but stops receiving rebuilds.
- Exactly one PHP version carries `default: true`. It backs `:latest`.
- `php.<version>.debian` overrides `defaults.debian` - the transition mechanism of §3.1, unset in normal operation.
- `images.<name>.parent` defines build order. CI topologically sorts; no hand-maintained ordering.
- `size_budgets` are frozen against measurement, one milestone at a time. CI fails on exceeding them. `runtime` was measured and frozen in M1 (§3.2, `docs/size-report-m1.md`); `cli`/`fpm`/`builder` are still provisional until M2 and `queue`/`scheduler` until M3. Those five are known to be *below* `runtime`, which they descend from, so they fail the moment those images build - deliberately, as the reminder to measure.

Matrix size: 3 PHP × 6 images × 2 arches = **36 build legs** per release. Development builds cut this to affected images on amd64 only.

---

## 6. Runtime Contract

The public API of the images. Changes here are breaking changes.

### 6.1 Filesystem and identity

| Property          | Value                                                    |
|-------------------|----------------------------------------------------------|
| User / group      | `laravel` (1000:1000)                                    |
| Working directory | `/var/www/html`                                          |
| App ownership     | `laravel:laravel`                                        |
| Writable paths    | `/var/www/html/storage`, `/var/www/html/bootstrap/cache` |
| Init              | `/usr/bin/tini -- <entrypoint>`                          |
| LaraOCI assets    | `/usr/local/share/laraoci/`                              |

All images run as `USER laravel`. No `sudo`, no setuid binaries beyond what Debian ships.

### 6.2 Signals and lifecycle

- `ENTRYPOINT` and `CMD` are **exec form** in every image.
- `pcntl` and `posix` are compiled in. Without them `queue:work` cannot trap `SIGTERM` and every deploy kills jobs mid-execution.
- `STOPSIGNAL SIGTERM`, stated explicitly.
- Documented requirement: the orchestrator's grace period must exceed the longest job timeout (`terminationGracePeriodSeconds`, `stop_grace_period`).

### 6.3 Logging

Everything to stdout/stderr. No log files in the container.

- `error_log = /proc/self/fd/2`, `log_errors = On`, `display_errors = Off`
- FPM: `error_log = /proc/self/fd/2`, `access.log = /proc/self/fd/2`, `daemonize = no`, `catch_workers_output = yes`, `decorate_workers_output = no`

`decorate_workers_output = no` matters: without it FPM prefixes every worker line and breaks JSON log parsing downstream.

**Most of this comes free from upstream.** The official `-fpm` image already writes `php-fpm.d/docker.conf` containing `clear_env = no`, both log redirections, `catch_workers_output`, `decorate_workers_output`, `log_limit`, and `listen = 9000`, plus `zz-docker.conf` with `daemonize = no`. LaraOCI's job is therefore **not to set these but to avoid clobbering them**, and to assert them in tests so an upstream change surfaces as a red build rather than a silent regression. LaraOCI's own pool file is additive (§7.3).

### 6.4 Environment

**`clear_env = no` in the FPM pool.** The single most common Laravel-in-Docker failure: with the FPM default, the application sees none of the container's environment and silently falls back to defaults.

| Variable                            | Default                                                   | Applies to   |
|-------------------------------------|-----------------------------------------------------------|--------------|
| `PHP_MEMORY_LIMIT`                  | `256M` (fpm) / `512M` (cli)                               | all          |
| `PHP_MAX_EXECUTION_TIME`            | `30` (fpm) / `0` (cli)                                    | all          |
| `PHP_UPLOAD_MAX_FILESIZE`           | `16M`                                                     | all          |
| `PHP_POST_MAX_SIZE`                 | `16M`                                                     | all          |
| `PHP_OPCACHE_ENABLE`                | `1`                                                       | all          |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS`   | `0`                                                       | all          |
| `PHP_OPCACHE_MEMORY_CONSUMPTION`    | `192`                                                     | all          |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | `20000`                                                   | all          |
| `PHP_OPCACHE_PRELOAD`               | *(unset)*                                                 | all          |
| `LARAOCI_PRELOAD_ROOT`              | `/var/www/html`                                           | all          |
| `LARAOCI_PRELOAD_PATHS`             | `vendor/laravel/framework/src/Illuminate,vendor/composer` | all          |
| `LARAOCI_PRELOAD_IGNORE`            | see §7.7                                                  | all          |
| `MAGICK_THREAD_LIMIT`               | `1`                                                       | all          |
| `MAGICK_TMPDIR`                     | `/tmp`                                                    | all          |
| `PHP_FPM_PM`                        | `dynamic`                                                 | fpm          |
| `PHP_FPM_MAX_CHILDREN`              | `20`                                                      | fpm          |
| `PHP_FPM_START_SERVERS`             | `4`                                                       | fpm          |
| `PHP_FPM_MIN_SPARE_SERVERS`         | `2`                                                       | fpm          |
| `PHP_FPM_MAX_SPARE_SERVERS`         | `6`                                                       | fpm          |
| `PHP_FPM_MAX_REQUESTS`              | `500`                                                     | fpm          |

Rendered by the entrypoint via `envsubst` against templates in `/usr/local/share/laraoci/templates/`. The generated file is `zz-laraoci.ini`, so any lexically later mount wins.

### 6.5 PHP configuration baseline

```ini
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /proc/self/fd/2
date.timezone = UTC
realpath_cache_size = 4096K
realpath_cache_ttl = 600

opcache.enable = 1
opcache.enable_cli = 1
opcache.validate_timestamps = 0
opcache.revalidate_freq = 0
opcache.memory_consumption = 192
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.jit = disable
```

`opcache.enable_cli = 1` is deliberate: `queue` and `scheduler` are long-lived CLI processes. `validate_timestamps = 0` means **the container must be replaced to pick up code changes** - correct for immutable deploys, documented loudly for anyone bind-mounting source.

No `disable_functions`. Laravel and its ecosystem use `proc_open` and `exec` legitimately; blanket disabling produces confusing breakage rather than security.

---

## 7. Per-Image Specification

### 7.1 `runtime`

Installs: CA certificates, `tini`, the core extension set, the hardened ImageMagick policy, the `laravel` user, the ini baseline, the preload script, and the entrypoint.

Does **not** install: Composer, git, Node, build toolchains, **Ghostscript**, `procps`.

Removed before the layer commits: `docker-php-extension-installer`, `*-dev` packages, apt lists.

```dockerfile
ARG PHP_VERSION
ARG DEBIAN_RELEASE=trixie
FROM php:${PHP_VERSION}-fpm-${DEBIAN_RELEASE}

ARG USER_UID=1000
ARG USER_GID=1000

COPY --from=mlocati/php-extension-installer:2 \
     /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions \
      bcmath exif gd imagick intl opcache pcntl \
      pdo_mysql pdo_pgsql redis sockets zip \
 && apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && apt-get purge -y --auto-remove ghostscript \
 && rm -rf /var/lib/apt/lists/* /usr/local/bin/install-php-extensions

# Policy lands in whichever ImageMagick config dir exists (6 vs 7)
COPY config/imagemagick/policy.xml /tmp/policy.xml
RUN set -eux; \
    for d in /etc/ImageMagick-7 /etc/ImageMagick-6; do \
      [ -d "$d" ] && install -m 0644 /tmp/policy.xml "$d/policy.xml"; \
    done; \
    rm /tmp/policy.xml

RUN groupadd -g ${USER_GID} laravel \
 && useradd -u ${USER_UID} -g laravel -m -s /bin/sh laravel \
 && mkdir -p /var/www/html \
 && chown laravel:laravel /var/www/html

COPY --chmod=0644 config/php/*.template  /usr/local/share/laraoci/templates/
COPY --chmod=0644 config/php/preload.php  /usr/local/share/laraoci/preload.php
COPY --chmod=0755 bin/entrypoint.sh       /usr/local/bin/laraoci-entrypoint

ENV MAGICK_THREAD_LIMIT=1 MAGICK_TMPDIR=/tmp

WORKDIR /var/www/html
USER laravel
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/laraoci-entrypoint"]
CMD ["php", "-v"]
```

*Illustrative - labels, digest pinning, and healthcheck omitted; see §11.*

**Risk retired.** The concern was that PECL imagick lags new PHP minors. `docker-php-extension-installer`'s support matrix lists `imagick` - along with every other extension in the §5 core set - as supported on **5.5 through 8.5** inclusive. D13 and D15 are compatible; the extension set stays uniform across all three versions rather than becoming per-version.

### 7.2 `cli`

`runtime` plus a default command. For `php artisan migrate`, `tinker`, ad-hoc tasks, and as parent of `queue`/`scheduler`.

```dockerfile
CMD ["php", "artisan", "list"]
```

No Composer (D6).

### 7.3 `fpm`

`runtime` plus a pool overlay and a command. **No SAPI installation** - `runtime` already carries `php-fpm` by way of D18.

The upstream image supplies `php-fpm.d/docker.conf` and `zz-docker.conf`, which between them already set `clear_env = no`, both log redirections, `catch_workers_output = yes`, `decorate_workers_output = no`, `listen = 9000`, and `daemonize = no`. LaraOCI adds only what is missing. The file is named `zz-laraoci.conf`, which sorts after `zz-docker.conf`, so LaraOCI wins where the two overlap and a consumer mount can still win over both.

FPM concatenates `php-fpm.d/*.conf` in glob order and section headers persist across file boundaries, so the LaraOCI file must declare its own `[www]` header rather than relying on the preceding file's.

```ini
[www]
user = laravel
group = laravel
listen = 0.0.0.0:9000
clear_env = no
catch_workers_output = yes
decorate_workers_output = no
access.log = /proc/self/fd/2

pm = ${PHP_FPM_PM}
pm.max_children = ${PHP_FPM_MAX_CHILDREN}
pm.start_servers = ${PHP_FPM_START_SERVERS}
pm.min_spare_servers = ${PHP_FPM_MIN_SPARE_SERVERS}
pm.max_spare_servers = ${PHP_FPM_MAX_SPARE_SERVERS}
pm.max_requests = ${PHP_FPM_MAX_REQUESTS}

ping.path = /fpm-ping
ping.response = pong
pm.status_path = /fpm-status

php_admin_value[error_log] = /proc/self/fd/2
php_admin_flag[log_errors] = on
```

`clear_env`, the log redirections, and `daemonize` are inherited from upstream and deliberately **not** repeated here - restating them would mean maintaining a second copy that can silently drift. They are asserted in tests instead (§10.1). `EXPOSE 9000` is likewise already set upstream.

**Healthcheck:** `cgi-fcgi -bind -connect 127.0.0.1:9000` against `/fpm-ping`, requiring `libfcgi-bin` (~200 KB) in `fpm` only. A container that cannot report its own health is worse than one 200 KB larger.

### 7.4 `builder`

`runtime` plus Composer, git, unzip, Node LTS, npm. **Not for production runtime** - stated in the description, the README, and `org.opencontainers.image.description`.

```dockerfile
FROM ghcr.io/laraoci/builder:8.4 AS build
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --prefer-dist --no-interaction
COPY . .
RUN composer dump-autoload --optimize --classmap-authoritative \
 && npm ci && npm run build

FROM ghcr.io/laraoci/fpm:8.4
COPY --from=build --chown=laravel:laravel /var/www/html /var/www/html
```

`COMPOSER_HOME` and the npm cache path are part of the runtime contract so consumers can mount BuildKit caches.

**D3a - reversing the v1 draft's amd64-only builder.** The original rationale was that Node toolchain builds under QEMU emulation are punishingly slow. That rationale is obsolete: native ARM64 GitHub-hosted runners are available, so the ARM builder leg runs natively at roughly amd64 speed. Meanwhile, the consumer-side argument is strong - every developer on Apple Silicon running this multi-stage build locally would otherwise emulate the entire `composer install` and `npm ci`. Builder ships multi-arch.

### 7.5 `queue`

```dockerfile
FROM ghcr.io/laraoci/cli:${TAG}
CMD ["php", "artisan", "queue:work", \
     "--no-interaction", "--tries=3", "--max-time=3600", "--rest=0.1"]
```

`--max-time=3600` bounds worker lifetime so leaks and stale state never accumulate; the container restarts cleanly.

No `HEALTHCHECK`. A queue worker has no meaningful synchronous health signal, and a naive one is worse than none. Documented alternative: `queue:monitor` on a schedule, or Horizon.

Documented warning: **the orchestrator grace period must exceed `--timeout`.** Laravel's 60 s default job timeout against Docker's 10 s default grace kills in-flight jobs on every deploy.

### 7.6 `scheduler`

```dockerfile
FROM ghcr.io/laraoci/cli:${TAG}
CMD ["php", "artisan", "schedule:work", "--no-interaction"]
```

Documented constraint: **exactly one replica.** Two scheduler containers double-fire every task. HA requires `withoutOverlapping` and a shared cache lock - application configuration, not image configuration.

### 7.7 Preload (D14)

Ships at `/usr/local/share/laraoci/preload.php`, **inert unless** `PHP_OPCACHE_PRELOAD` names it.

```bash
PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
PHP_OPCACHE_MEMORY_CONSUMPTION=320
```

```php
<?php
declare(strict_types=1);

$root   = getenv('LARAOCI_PRELOAD_ROOT') ?: '/var/www/html';
$paths  = getenv('LARAOCI_PRELOAD_PATHS')
       ?: 'vendor/laravel/framework/src/Illuminate,vendor/composer';
$ignore = getenv('LARAOCI_PRELOAD_IGNORE')
       ?: '/tests/,/Tests/,/stubs/,/Stubs/,/Testing/,/migrations/,/resources/';

$ignores  = array_filter(explode(',', $ignore));
$compiled = $skipped = 0;

// "Can't preload unlinked class" is a benign warning; keep startup logs clean.
set_error_handler(static fn () => true);

foreach (array_filter(explode(',', $paths)) as $relative) {
    $dir = rtrim($root, '/') . '/' . trim($relative, '/');
    if (! is_dir($dir)) {
        continue;
    }

    $files = new RegexIterator(
        new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)
        ),
        '/\.php$/'
    );

    foreach ($files as $file) {
        $path = $file->getPathname();

        foreach ($ignores as $needle) {
            if (str_contains($path, $needle)) {
                $skipped++;
                continue 2;
            }
        }

        try {
            opcache_compile_file($path) ? $compiled++ : $skipped++;
        } catch (Throwable) {
            $skipped++;
        }
    }
}

restore_error_handler();
fwrite(STDERR, sprintf(
    "laraoci: preloaded %d files, skipped %d%s", $compiled, $skipped, PHP_EOL
));
```

Constraints documented alongside it:

- **Preload is FPM-only by default (D22).** Setting `PHP_OPCACHE_PRELOAD` is necessary but not sufficient: the entrypoint writes the `opcache.preload` directive into `zz-laraoci-preload.ini` only when the launched command is `php-fpm`. CLI opcache is per-process - the shared segment is created at startup and destroyed at exit - so on `cli` every `php artisan` call would pay the full preload compile cost and discard the result. Long-lived CLI workers that genuinely benefit, `queue` above all, opt in with **`LARAOCI_PRELOAD_FORCE=1`**. A stale directive from a previous start is cleared on the next one, so a container that stops qualifying does not keep preloading. `opcache.enable_cli` stays `1` regardless (§6.5) - that is what makes queue workers worth the opt-in.
- **Requires `vendor/` to exist at container start.** With an empty root the script no-ops and logs zero - silent, not fatal, by design.
- **Requires a container restart to change anything preloaded.** Consistent with `validate_timestamps = 0`.
- **Costs opcache memory.** Preloaded entries count against `opcache.memory_consumption`; the documented pairing raises it to 320 MB. `max_accelerated_files` must exceed the preloaded file count.
- **No `opcache.preload_user` needed.** That directive is only required when the FPM master runs as root; LaraOCI runs as `laravel` throughout.
- Application code is deliberately *not* in the default path set. Preloading app classes is a real optimisation but is application-specific; consumers point `LARAOCI_PRELOAD_PATHS` at `app` themselves.
- **`vendor/symfony` is deliberately excluded from the default**, reversing the v1 draft. Illuminate's own preloading drags in the Symfony components it actually uses; compiling the full tree additionally loads Console, Mailer, and HttpKernel subtrees that most applications never touch, inflating preload memory for no hit-rate gain. It is also the largest source of benign "unlinked class" skips, which makes the startup line misleading. Documented as an opt-in append.
- Tuning is measurable: `opcache_get_status()['preload_statistics']` reports the memory consumed and the class/function counts. The docs show this rather than asserting a number.

---

## 8. Tagging Policy

Each image type is its own GHCR package: `ghcr.io/laraoci/{runtime,cli,fpm,builder,queue,scheduler}`.

| Tag form      | Example                   | Mutability    | Use                      |
|---------------|---------------------------|---------------|--------------------------|
| PHP minor     | `:8.4`                    | Rolling       | Dev, non-critical        |
| PHP + Debian  | `:8.4-trixie`             | Rolling       | Explicit OS pin          |
| Dated         | `:8.4-trixie-20260724`    | **Immutable** | Production               |
| Patch + dated | `:8.4.10-trixie-20260724` | **Immutable** | Strict pinning           |
| Digest        | `@sha256:…`               | **Immutable** | Supply-chain-strict      |
| `:latest`     |                           | Rolling       | Default PHP version only |

- Dated tags are **never** overwritten; a same-day rebuild appends `-2`.
- Rolling tags are repointed by scheduled rebuilds (§9.3), in a job gated on the whole matrix. A partially-failed matrix must never leave `:8.4` half-updated.
- README recommends dated tags or digests for production, with Renovate and Dependabot config examples.

---

## 9. Build Pipeline

### 9.1 Development builds (`pull_request`)

Affected images only - changed paths mapped through the `parent` graph, so a `runtime` change rebuilds everything downstream and a `queue` change rebuilds only `queue`. amd64 only, GHA layer cache, built and loaded but not pushed, full test suite (§10), advisory-only vulnerability scan.

### 9.2 Release builds (tag push or manual dispatch)

Full 36-leg matrix. Native amd64 and arm64 runners, multi-platform manifest lists, SPDX SBOM, SLSA provenance (`mode=max`), Cosign keyless signing via GitHub OIDC. Vulnerability scan is a **hard gate** on fixable `CRITICAL` and `HIGH`. Size budgets (D17) enforced. Rolling tags repointed only after every leg succeeds.

### 9.3 Scheduled rebuilds (weekly)

This is what keeps "secure" true. Upstream PHP images and Debian packages receive fixes continuously; an image built once accumulates CVEs no matter how careful the original build was.

Unconditional weekly rebuild of all `supported` versions - cheap, and avoids missing package-level updates that don't move the upstream digest. Produces a new dated tag and repoints rolling tags. On scan failure the run fails loudly and opens an issue rather than publishing.

Because imagick is now in the base layer (D13), the scheduled rebuild is not optional hygiene - it is the primary control on the largest CVE surface in the image.

---

## 10. Testing Strategy

### 10.1 Structure tests

`container-structure-test` per image, asserting §6:

- Runs as UID 1000
- `pcntl`, `posix`, `opcache`, `imagick` loaded
- `opcache.validate_timestamps = 0`, `expose_php = Off`
- **ImageMagick major version is 7** - asserted via `Imagick::getVersion()`
- **Policy is live**, asserted *through PHP* rather than through `identify -list policy`: the CLI tools are not installed (§3.2), so the test opens a `PDF:` pseudo-image and an `@`-prefixed indirect read and requires both to throw `ImagickException`
- **Ghostscript absent** - `command -v gs` fails
- Composer absent from `cli`/`fpm`/`queue`/`scheduler`, present in `builder`
- `clear_env = no` in the rendered FPM pool
- `tini` is PID 1
- `/var/www/html` owned by `laravel`
- **Compressed size within the `size_budgets` value** (D17)

### 10.2 Functional smoke test

Minimal Laravel skeleton at `tests/fixtures/app`:

1. `builder` -> `composer install`, `npm ci && npm run build`
2. `cli` -> `artisan migrate` on SQLite, `artisan about`
3. `fpm` + throwaway Nginx -> HTTP 200 on `/`, `/fpm-ping` returns `pong`
4. `queue` -> dispatch a job, assert processing, then `SIGTERM` mid-job and assert **graceful completion, not truncation** (the pcntl regression test)
5. `scheduler` -> run 70 s, assert exactly one execution of a per-minute task
6. **imagick** -> resize a JPEG through the `Imagick` class, then assert a crafted `PDF:` and an `@file` read both **fail** under policy
7. **preload** -> boot `fpm` with `PHP_OPCACHE_PRELOAD` set, assert non-zero preloaded count in stderr and HTTP 200 still served; boot with an empty `vendor/` and assert the container still starts

### 10.3 Environment passthrough test

Set an arbitrary env var on the `fpm` container, hit a route echoing `env()`, assert visibility. This is the `clear_env` regression test, and it gets its own named test because the failure mode is silent.

---

## 11. Supply Chain & Metadata

Every published image carries OCI labels (`source`, `revision`, `created`, `version`, `licenses`, `description`, `documentation`, `base.name`, `base.digest`), an SPDX SBOM attestation, SLSA provenance, a Cosign keyless signature, and a scan report uploaded to GitHub code scanning.

`cosign verify` instructions with the expected identity and issuer belong in the README, not only in CI. An unverifiable signature is decorative.

---

## 12. Repository Layout

```
.
├── config/
│   ├── images.yml
│   ├── imagemagick/policy.xml
│   └── php/
│       ├── zz-laraoci.ini.template
│       ├── zz-laraoci-fpm.conf.template
│       └── preload.php
├── images/
│   ├── runtime/Dockerfile
│   ├── cli/Dockerfile
│   ├── fpm/Dockerfile
│   ├── builder/Dockerfile
│   ├── queue/Dockerfile
│   └── scheduler/Dockerfile
├── bin/
│   ├── matrix.sh          # images.yml -> GHA JSON matrix
│   ├── affected.sh        # changed paths -> affected images
│   ├── size-check.sh      # D17 budget enforcement
│   └── entrypoint.sh
├── tests/
│   ├── structure/*.yaml
│   ├── fixtures/app/
│   └── smoke/*.sh
├── docs/
└── .github/workflows/{build,pr,release,scheduled}.yml
```

---

## 13. Support Policy

- A PHP version is `supported` while it receives upstream **security** support, then `deprecated`.
- `deprecated` versions keep their dated tags forever but stop receiving scheduled rebuilds. The rolling tag freezes and the README states the freeze date.
- Debian follows §3.1: one release for the whole matrix, migrated deliberately.
- LaraOCI's SemVer applies to the **runtime contract** (§6), not the PHP inside. Changing the UID, workdir, entrypoint behaviour, or a documented env default is a major bump. Adding or removing an extension is a minor bump and a release-note callout.

---

## 14. Non-Goals

LaraOCI is not a replacement for Docker Compose or Kubernetes, a deployment platform, a source of opinionated infrastructure (no Nginx, no databases, no Redis server, no Supervisor), or a kitchen-sink extension bundle.

Explicitly out of scope: web server configuration, TLS termination, secrets management, database provisioning, process supervision beyond one process per container, and - per D13 - **PDF and PostScript rasterisation**, which requires Ghostscript and is left to consumers who consciously want it.

Two deliberate exceptions, both argued rather than assumed: the `builder` image (§7.4), because the alternative is Composer in production images; and FrankenPHP post-v1 (§3.3), because there the server is the SAPI.

---

## 15. Roadmap

| Milestone                       | Content                                                                                                                                                                                                                                                                  | Exit criteria                                                                                                      |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| **M0 - Foundations**            | Repo scaffold, `config/images.yml`, matrix + affected + size-check scripts, PR workflow skeleton. Upstream trixie coverage already confirmed.                                                                                                                            | Matrix generation tested; empty build passes CI                                                                    |
| **M1 - Runtime**                | `runtime` image, extension set, **imagick + hardened policy**, ini baseline, entrypoint templating, user/UID, tini. **Measure real sizes and freeze budgets** - the §5 numbers are placeholders. Confirm the Ghostscript purge survives the installer's package marking. | Structure tests green on `runtime` for all three PHP versions, including policy and Ghostscript-absence assertions |
| **M2 - First images**           | `cli`, `fpm`, `builder`                                                                                                                                                                                                                                                  | Smoke tests 1–3 and 6 green; env passthrough green                                                                 |
| **M3 - Workers & preload**      | `queue`, `scheduler`, preload script and docs                                                                                                                                                                                                                            | Smoke tests 4, 5, 7 green, including SIGTERM graceful shutdown                                                     |
| **M4 - Release pipeline**       | Multi-arch, manifests, SBOM, provenance, Cosign, scan gate, size gate, tagging policy                                                                                                                                                                                    | First signed multi-arch release on GHCR, verified with `cosign verify`                                             |
| **M5 - Maintenance**            | Scheduled rebuild workflow, deprecation tooling, docs site, Renovate examples                                                                                                                                                                                            | One full scheduled cycle completed, rolling tags repointed                                                         |
| **M6 - FrankenPHP** *(post-v1)* | Design note first (§3.3), then implementation                                                                                                                                                                                                                            | Runtime contract §6 demonstrably upheld on the second root                                                         |

---

## 16. Resolved Decisions

| v1 question           | Resolution                                                    |
|-----------------------|---------------------------------------------------------------|
| PHP version floor     | 8.3, 8.4, 8.5 - all `supported`, no preview tier (D15)        |
| Shared layer naming   | `runtime` (D2)                                                |
| imagick               | Included, with hardened policy and no Ghostscript (D13)       |
| ARM builder           | Multi-arch - earlier amd64-only recommendation reversed (D3a) |
| Preload               | Opt-in script shipped at a fixed path (D14)                   |
| First post-v1 variant | FrankenPHP, with an accepted second root (D16)                |

## 17. Remaining Open Questions

Questions 1–3 of the v2 draft are closed against primary sources and folded into §3.1, §3.2, and §7.1. Questions 1 and 3 of the v3 list - the `runtime` size budget and the `libmagickcore-*-extra` scope - are closed against **M1 measurement** and folded into §3.2 and §5; the numbers and method live in `docs/size-report-m1.md`. What is left is genuinely unresolvable from a desk.

1. **Ghostscript purge durability.** The purge depends on `install-php-extensions` continuing to install Ghostscript as a normal package rather than pinning or holding it. M1 made this sharper, not softer: because the tree must be named explicitly (§3.2), a rename such as `libgs10` → `libgs11` breaks the build rather than silently leaving the interpreter behind - loud, but on an unrelated PR. The structure test is the backstop. Still worth an upstream issue asking whether Ghostscript can be made opt-out.
2. **PHP 8.6.** An alpha is already built upstream with full trixie coverage. Confirm the intent to add it at GA as a fourth `supported` version - which takes the release matrix from 36 legs to 48 and makes the affected-images filter (§9.1) load-bearing rather than a nicety.
3. **Budgets for the other five images.** `runtime` is frozen; `cli`, `fpm`, `builder`, `queue`, and `scheduler` still carry v2-draft placeholders that sit *below* their own parent. M2 and M3 measure and freeze them the same way. Not a desk question either - it needs the images to exist.
