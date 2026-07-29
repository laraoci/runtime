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

# Both toolchains arrive as digest-pinned COPY --from - the mechanism runtime
# already uses for install-php-extensions (D19). Multi-arch by construction,
# no third-party apt repository, no `curl | sh`, and Renovate updates a digest.
#
# ONLY node's own paths are copied. `COPY --from=node /usr/local /usr/local`
# would overwrite PHP's entire installation, which lives in the same prefix.
# node's binary is glibc-linked against the same Debian suite as this image.
COPY --from=composer/composer:2-bin@sha256:cf313f79f608ebab80220796327f341ae663b9fa8065c73c6148c9b67f0b13b3 /composer /usr/local/bin/composer
COPY --from=node:LTS-trixie-slim@sha256:ae91dcc111a68c9d2d81ff2a17bda61be126426176fde6fe7d08ab13b7f50573 /usr/local/bin/node /usr/local/bin/node
COPY --from=node:LTS-trixie-slim@sha256:ae91dcc111a68c9d2d81ff2a17bda61be126426176fde6fe7d08ab13b7f50573 /usr/local/lib/node_modules /usr/local/lib/node_modules

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
USER root
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends git unzip; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx; \
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
# can mount BuildKit caches onto them. COMPOSER_ALLOW_SUPERUSER=0 is explicit
# rather than assumed - it is what makes composer refuse to run as root quietly
# instead of warning on every invocation if someone builds with --user 0.
ENV COMPOSER_HOME=/home/${USER_NAME}/.composer \
    COMPOSER_ALLOW_SUPERUSER=0 \
    NPM_CONFIG_CACHE=/home/${USER_NAME}/.npm \
    NPM_CONFIG_UPDATE_NOTIFIER=false

CMD ["composer", "--version"]
