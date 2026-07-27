# Claude Code Session - M1: Runtime

## Context

You are building **`laraoci/runtime`**, the shared base layer every other LaraOCI image descends from. This is the highest-stakes session in the project: the runtime contract established here (spec §6) is the public API of all six images, and changing it later is a major version bump.

Read before planning:

- `laraoci-spec.md` - §3.2 (imagick), §3.4 (why the fpm base), §6 (the runtime contract in full), §7.1 (the runtime image), §7.7 (preload), §10.1 (structure tests)
- `laraoci-issues.md`
- `config/images.yml` as merged in M0

Issues in scope: **LOCI-011 through LOCI-021**.

---

## Operating rules

### 🚦 Plan before code

**Write nothing until I approve the plan.** Gate 1 is below.

There is a second gate mid-session: 🚦 Gate 2, after the Dockerfile builds but before structure tests are written. I want to inspect the built image myself.

### 🧭 Decision gates

Stop and ask. Options, recommendation, one-line rationale each.

### Quality gates - non-negotiable

- `hadolint` clean on the Dockerfile
- `shellcheck -S warning` and `shfmt -d -i 2 -ci` clean on the entrypoint
- Builds green on **8.3, 8.4, and 8.5**
- `container-structure-test` green on all three
- Image sizes measured and budgets committed as real numbers

### Working style

- One commit per issue.
- If the spec is wrong, **stop and say so**. Two spec errors have already been caught this way - the FPM-on-a-cli-base impossibility and the Ghostscript-is-installed-by-the-installer surprise. Assume more remain.

---

## Five traps that will silently ruin this image

Read these before you plan. Each produces a working image that is quietly wrong.

### 1. The Ghostscript purge must be in the *same* `RUN` as the extension install

Docker layers are additive. Deleting a file in a later `RUN` does not remove its bytes from the earlier layer - the image still carries them, they still count toward size, and the binary is still extractable from the layer tarball. A purge in its own `RUN` for readability produces an image that **passes `command -v gs` and still ships Ghostscript**.

Install and purge must be chained with `&&` in one instruction. Add a comment saying why, because this is exactly the kind of thing a future tidy-up refactors apart.

### 2. `envsubst` with no arguments will destroy the FPM config

Bare `envsubst` substitutes **every** `$VAR` in its input. FPM pool files use `$pool` as a built-in variable, and php.ini values can contain `$`. Unrestricted substitution silently blanks them.

Call `envsubst` with an explicit allowlist: `envsubst '${PHP_MEMORY_LIMIT} ${PHP_FPM_MAX_CHILDREN} ...'`. Generate the allowlist from the documented variable set in §6.4 rather than hand-maintaining a second copy.

### 3. Preload in CLI is pure overhead

`opcache.enable_cli = 1` is correct for long-running queue workers. But CLI opcache is **per-process** - the shared memory segment is created at startup and destroyed at exit, so nothing persists between invocations. With `opcache.preload` also set, every single `php artisan` call pays the full preload compile cost and throws the result away.

This makes preload actively harmful for the `cli` image and for one-off tasks. See 🧭 Decision 4.

### 4. The ImageMagick policy directory does not exist until imagick is installed

The policy `COPY` and the directory detection must come after the extension install, not before. Detect rather than hardcode: trixie is ImageMagick 7 today, and the whole point of detection is surviving the suite bump that changes it.

### 5. Upstream already configures most of FPM

The official `-fpm` image writes `php-fpm.d/docker.conf` with `clear_env = no`, both log redirections, `catch_workers_output`, `decorate_workers_output`, `log_limit`, and `listen = 9000`, plus `zz-docker.conf` with `daemonize = no`.

Do **not** restate these. A second copy drifts silently. LaraOCI's job is to not clobber them and to assert them in tests. This session should verify they survive; M2 adds only the missing pieces.

---

## 🚦 Gate 1 - Present this plan and wait

1. **The Dockerfile in full**, as you intend to commit it. Annotate every `RUN` boundary with why it is a boundary - layer splits are load-bearing here (trap 1).
2. **The entrypoint script in full**, including how the `envsubst` allowlist is generated (trap 2).
3. **Where `docker-php-entrypoint` fits** - see 🧭 Decision 2.
4. **Template files** - `zz-laraoci.ini.template` content.
5. **Structure test list** - every assertion, mapped to the §6 contract clause it protects.
6. **Size measurement plan** - how you will produce the numbers that replace the `size_budgets` placeholders, and how you will isolate the `libmagickcore-*-extra` contribution specifically (that number feeds LOCI-056).
7. **The 🧭 decisions**, with recommendations.

---

## Work items

### LOCI-011 - Dockerfile skeleton and upstream pin

`FROM php:${PHP_VERSION}-fpm-${DEBIAN_RELEASE}` - the **fpm** variant, per D18/§3.4. It ships `/usr/local/bin/php` as well as `php-fpm`; a `-cli` base cannot gain FPM without recompiling PHP.

First thing to verify once it builds: **both `php -v` and `php-fpm -v` work.** If either does not, stop - the whole graph rests on this.

### LOCI-012 - Non-root user and filesystem layout

UID/GID 1000, name `laravel`, sourced from `config/images.yml` via build args (D8, §6.1).

The base has `www-data` at 33 and no UID 1000. Do not assume that stays true - if `groupadd`/`useradd` collides, **fail loudly** rather than papering over it with `|| true`. A silently different UID is exactly the bug D8 exists to prevent.

`/var/www/html` exists in the fpm base but is root-owned; chown it. `USER laravel` goes last, after all apt work.

### LOCI-013 - Core extension installation

The twelve extensions from §5 via `docker-php-extension-installer` (D12). All are supported on 8.3–8.5, so the set stays uniform.

`pcntl` and `posix` are mandatory - without them queue workers cannot trap SIGTERM and every deploy truncates jobs (§6.2). Verify explicitly rather than trusting the install succeeded.

### LOCI-014 - Purge Ghostscript

See trap 1. Same `RUN`, no `|| true`, hard failure.

Afterwards, confirm `--auto-remove` reclaimed `libgs*`, `poppler-data`, `fonts-urw-base35`, and **confirm imagick still handles JPEG, PNG, and WebP**. Record the reclaimed size - it feeds LOCI-021.

### LOCI-015 - Hardened ImageMagick policy

`config/imagemagick/policy.xml` per §3.2: all delegates denied; the PS/EPS/PDF/XPS, MSL/MVG/MAGICK/TEXT/SHOW/WIN/PLT, and URL/HTTP/HTTPS/FTP coders denied; `path` pattern `@*` denied; resource limits including `thread=1`.

`ENV MAGICK_THREAD_LIMIT=1 MAGICK_TMPDIR=/tmp`. Thread limiting is a **correctness** fix as much as a security one - twenty FPM children each opening an OpenMP pool will thrash a CPU-limited container.

Install to whichever `/etc/ImageMagick-*` exists (trap 4).

### LOCI-016 - php.ini baseline

`config/php/zz-laraoci.ini.template` with the §6.5 baseline. Filename must sort last in `conf.d` so a user mount wins.

No `disable_functions` - Laravel uses `proc_open` and `exec` legitimately, and blanket disabling produces confusing breakage rather than security.

### LOCI-017 - Entrypoint and config rendering

See trap 2 and 🧭 Decision 2. Allowlist only the documented `PHP_*` variables; everything else passes through untouched. `exec` at the end - leave no wrapper in the process tree.

### LOCI-018 - tini and exec-form entrypoint

`tini` from apt, `/usr/bin/tini`. Exec-form `ENTRYPOINT`. `STOPSIGNAL SIGTERM` stated explicitly rather than inherited - the explicitness is the documentation.

### LOCI-019 - OCI labels

Including `base.name` and `base.digest`, so a consumer can identify the exact upstream image. Applied in the reusable workflow, not hand-written per Dockerfile.

### LOCI-020 / LOCI-021 - Structure tests and the budget freeze

**Assert the policy through PHP, not `identify`.** The image ships no ImageMagick CLI tools - only libraries - so `identify -list policy` does not exist. Open a `PDF:` pseudo-image and an `@`-prefixed indirect read; both must throw `ImagickException`.

Full assertion list in §10.1. Then measure real compressed sizes on all three versions and **replace the placeholders in `config/images.yml` with the measured values**, isolating the `libmagickcore-*-extra` contribution.

---

## 🧭 Decision gates

### 🧭 1 - Pin `install-php-extensions` by tag or digest?

Tag (`:2`) picks up fixes automatically but makes builds non-deterministic across time. Digest is deterministic but needs Renovate to stay current. Given the project's own immutability stance (§2.4), I lean digest - but say what you think.

### 🧭 2 - Chain or replace `docker-php-entrypoint`?

Upstream's entrypoint prepends the default binary when the first argument starts with `-`, so `docker run image -v` works. Replacing it outright loses that.

Options: chain (`exec docker-php-entrypoint "$@"` at the end of ours), replicate its logic, or replace and accept the loss. Chaining preserves upstream behaviour and keeps us honest about not reimplementing what we inherit - but confirm the interaction with tini is what you expect.

### 🧭 3 - `procps` for debugging?

Absent by default per §7.1, which means no `ps` inside a running container. Defensible for attack surface; irritating during incidents. Small either way. Recommend and move on.

### 🧭 4 - Should preload be scoped away from CLI?

See trap 3. Options: leave `opcache.enable_cli=1` and document that preload is FPM/queue-only; render `PHP_OPCACHE_PRELOAD` into an FPM-specific ini so `cli` cannot accidentally enable it; or disable `enable_cli` entirely (which would hurt queue workers).

This decision belongs to M1 because it shapes where the ini templates live, even though the preload script itself is M3. Flag whichever you pick for the §7.7 documentation.

---

## 🚦 Gate 2 - After the build, before the tests

Once the Dockerfile builds on all three versions, stop and report:

- `docker history` output, so I can see the layer boundaries
- Confirmation that `php -v`, `php-fpm -v`, and `php -m` all behave
- `command -v gs` result, **and** confirmation that Ghostscript is absent from the layer tarball, not merely from the final filesystem (trap 1)
- Which `/etc/ImageMagick-*` directory the policy landed in
- Measured sizes for all three versions

I will inspect before you write structure tests.

---

## Definition of done

- [ ] All eleven issues closed
- [ ] Builds green on 8.3, 8.4, 8.5
- [ ] Structure tests green, including the PHP-level policy assertions
- [ ] Ghostscript absent from the layer tarball, verified
- [ ] `size_budgets` committed as measured values, with the `-extra` contribution recorded
- [ ] All four 🧭 decisions recorded in the spec's decision register
