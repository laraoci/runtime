# syntax=docker/dockerfile:1

# LaraOCI builder - Composer and Node toolchain for multi-stage builds (§7.4,
# LOCI-026). NOT A PRODUCTION RUNTIME: it carries a package manager, a VCS
# client and a JavaScript runtime, none of which belong next to application
# code that serves requests. org.opencontainers.image.description says so, CI
# applies it from config/images.yml, and tests/structure/builder.yaml pins it.
#
# Multi-arch (D3a): every ingredient below resolves per target platform, so the
# arm64 leg builds natively on an arm64 runner with no QEMU.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
ARG PARENT_REF=ghcr.io/laraoci/runtime:${PHP_VERSION}-${DEBIAN_RELEASE}
FROM ${PARENT_REF}

ARG USER_NAME=laravel
ARG USER_UID=1000
ARG USER_GID=1000

# 🧭 1: builder runs CLI processes. A dash-first argument must not start FPM,
# and `composer install` must not be classified as an FPM process.
ENV LARAOCI_DEFAULT_BINARY=php

# §6.4's cli column, for the same reason cli carries it: composer's solver on a
# real Laravel tree does not fit in 256 MB, and a dependency install is not a
# 30-second operation. This is a deliberate reading of the table's "fpm/cli"
# split as being about SAPI shape rather than about the image called `cli`.
ENV PHP_MEMORY_LIMIT=512M \
    PHP_MAX_EXECUTION_TIME=0

# RE-RENDER, for the reason images/cli/Dockerfile states - and here it is not
# cosmetic: a builder stage on a read-only rootfs would run composer's solver
# under the parent's 256 MB, which line 26 above says does not fit.
#
# Same one-line idiom as images/fpm/Dockerfile:114, and it runs as `laravel`
# (inherited from runtime) against a file pre-created with that ownership.
RUN /usr/local/bin/laraoci-entrypoint true

# Both toolchains arrive as digest-pinned COPY --from - the mechanism runtime
# already uses for install-php-extensions (D19). Multi-arch by construction,
# no third-party apt repository, no `curl | sh`, and Renovate updates a digest.
#
# ONLY node's own paths are copied. `COPY --from=node /usr/local /usr/local`
# would overwrite PHP's entire installation, which lives in the same prefix.
# node's binary is glibc-linked against the same Debian suite as this image.
COPY --from=composer/composer:2-bin@sha256:cf313f79f608ebab80220796327f341ae663b9fa8065c73c6148c9b67f0b13b3 /composer /usr/local/bin/composer
COPY --from=node:lts-trixie-slim@sha256:ae91dcc111a68c9d2d81ff2a17bda61be126426176fde6fe7d08ab13b7f50573 /usr/local/bin/node /usr/local/bin/node
COPY --from=node:lts-trixie-slim@sha256:ae91dcc111a68c9d2d81ff2a17bda61be126426176fde6fe7d08ab13b7f50573 /usr/local/lib/node_modules /usr/local/lib/node_modules

# ---------------------------------------------------------------------------
# 🧭 3, first half - root time. git and unzip are composer's VCS and archive
# paths (§7.4); the npm/npx shims are the two symlinks the node image itself
# ships, recreated here because only node_modules was copied.
#
# The cache directories are created HERE, owned by laravel, because a consumer
# mounting a BuildKit cache onto them (`--mount=type=cache,uid=1000,...`) needs
# the mount point to exist with the right ownership - and because npm and
# composer both fall back to unpredictable locations when their configured cache
# is unwritable, which turns a cache miss into a silent per-build download.
#
# Every tool is executed once, as an assertion. A COPY --from that lands a
# binary the target platform cannot run fails HERE rather than in a consumer's
# build six weeks later.
#
# THE npm UPGRADE IS A CVE FIX, and the one place this image reaches past a
# digest pin (D42). node ships npm as a bundled tree, and that tree - not node
# itself - carries the findings: tar, undici, brace-expansion and ip-address all
# live under /usr/local/lib/node_modules/npm/node_modules. Bumping the node
# digest does NOT help; measured 2026-08-11, the newest node:lts-trixie-slim
# carries the identical set. Upgrading npm in place does: 7 findings to 3,
# including the CRITICAL node-tar gzip bomb - which matters here more than
# anywhere, because `npm ci` is exactly the thing that extracts untrusted
# tarballs (D26).
#
# PINNED BY CONTENT, not by version tag. Everything else this image consumes is
# a @sha256: digest, and every tool in the repository is a SHA-256 in tools.env;
# `npm install -g npm@12.0.2` was the one ingredient that resolved a name against
# a registry at build time and trusted the answer. The tarball is fetched and
# checked instead. The digest was verified against npm's own published
# dist.integrity on 2026-08-11 - they agree.
#
# Bumping the version means replacing BOTH the URL and the SHA-256. A mismatch
# fails the build here, which is the point.
USER root
# hadolint ignore=DL3008,DL4006
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends git unzip; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx; \
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 \
          https://registry.npmjs.org/npm/-/npm-12.0.2.tgz -o /tmp/npm.tgz; \
    echo "5dbb86c71d07a1957f2e90734092dd6a58bdcd9ebc2d8d41ca1c6e6a21d364e1  /tmp/npm.tgz" \
          | sha256sum -c -; \
    npm install -g /tmp/npm.tgz; \
    rm -f /tmp/npm.tgz; \
    install -d -o "${USER_UID}" -g "${USER_GID}" -m 0755 \
      "/home/${USER_NAME}/.composer" "/home/${USER_NAME}/.npm"; \
    composer --version; \
    node --version; \
    npm --version; \
    git --version; \
    unzip -v >/dev/null

# 🧭 3, second half - the default user is laravel again, so the `composer
# install` / `npm ci` a consumer runs in their build stage runs unprivileged and
# writes files owned 1000:1000, which is what the `COPY --from=build --chown`
# in §7.4's example expects.
USER ${USER_NAME}

# Part of the runtime contract (§7.4): these paths are documented so a consumer
# can mount BuildKit caches onto them.
#
# COMPOSER_ALLOW_SUPERUSER=0 IS INERT, TWICE OVER. It is kept, and said out loud
# here, so nobody has to measure it again to find that out. Read from Composer
# 2.10.2's own Console/Application.php:
#
#   $needsSudoCheck = !Platform::isWindows()
#     && function_exists('exec')
#     && !Platform::getEnv('COMPOSER_ALLOW_SUPERUSER')
#     && !Platform::isDocker();
#
# 1. TRUTHINESS, NOT isset. getenv() returns the string "0", which is falsy in
#    PHP, so `!getEnv(...)` is true and the conjunct passes exactly as it does
#    with the variable unset. Measured: var_dump gives string(1) "0" then
#    bool(false) - the same bool(false) an unset variable gives. Setting it to 0
#    and not setting it at all are the same thing.
#
# 2. AND IT COULD NEVER MATTER IN THIS IMAGE ANYWAY. Platform::isDocker() is
#    true whenever /.dockerenv exists, which is every container these images run
#    in, so $needsSudoCheck is false regardless of the variable and the root
#    check is skipped entirely. Measured both ways - as `--user 0` with the
#    variable at 0 and with it unset, `composer install` printed no root notice
#    in either case.
#
# And what the flag gates when it IS reached - a root invocation outside a
# container - is a WARNING plus an interactive "Continue as root/super user?"
# prompt, plus plugin disabling in a non-interactive session. Not a refusal.
# This comment previously claimed it made composer refuse; it never did.
#
# Kept rather than deleted because tests/structure/builder.yaml pins the ENV as
# part of the documented interface, and because a reader who knows the variable
# exists is better served by finding it with this note than by not finding it.
ENV COMPOSER_HOME=/home/${USER_NAME}/.composer \
    COMPOSER_ALLOW_SUPERUSER=0 \
    NPM_CONFIG_CACHE=/home/${USER_NAME}/.npm \
    NPM_CONFIG_UPDATE_NOTIFIER=false

CMD ["composer", "--version"]
