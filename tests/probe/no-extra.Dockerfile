# syntax=docker/dockerfile:1

# MEASUREMENT ONLY - never built by CI, never published, not in config/images.yml.
#
# Isolates the libmagickcore-*-extra contribution for spec §17 q3 / LOCI-056.
#
# Build it TWICE and diff the results:
#   docker build -f tests/probe/no-extra.Dockerfile --build-arg PURGE_EXTRA=0 \
#     -t laraoci-probe:with-extra .
#   docker build -f tests/probe/no-extra.Dockerfile --build-arg PURGE_EXTRA=1 \
#     -t laraoci-probe:no-extra .
#   contribution = size(with-extra) - size(no-extra)
#
# Two things this file gets right that a naive probe does not:
#
# 1. The purge happens inside the SAME RUN as the install. Layers are additive,
#    so removing a package in a later instruction reclaims nothing.
#
# 2. Both variants come from ONE file, differing only by PURGE_EXTRA. Diffing a
#    probe against images/runtime/Dockerfile instead would fold RUN 2, 3 and 4
#    into the delta, and - if the probe's Ghostscript purge drifts from the real
#    one - can even produce a NEGATIVE result. That is how the first version of
#    this file was caught: it still carried 38 MB of libgs, so the "smaller"
#    no-extra probe measured 239.0 MB against runtime's 230.5 MB.
#
# RUN 1 below must stay a mirror of images/runtime/Dockerfile's RUN 1, minus the
# assertions. If that instruction changes, change this one too, or the delta
# silently stops describing the image that actually ships.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
FROM php:${PHP_VERSION}-fpm-${DEBIAN_RELEASE}

ARG PURGE_EXTRA=1

COPY --from=mlocati/php-extension-installer:2@sha256:b6d3fa381b9ba5cf051117c1c601d6a523b590e534bf3d56eb4fbe352949c138 \
     /usr/bin/install-php-extensions /usr/local/bin/

# hadolint ignore=DL3008,SC2016
RUN set -eux; \
    install-php-extensions \
      bcmath exif gd imagick intl opcache pcntl \
      pdo_mysql pdo_pgsql redis sockets zip; \
    apt-get update; \
    apt-get install -y --no-install-recommends tini gettext-base; \
    apt-get purge -y --auto-remove \
      ghostscript libgs10 libgs10-common libgs-common poppler-data; \
    if [ "${PURGE_EXTRA}" = "1" ]; then \
      apt-get purge -y --auto-remove 'libmagickcore-*-extra'; \
    fi; \
    php -r 'if (! extension_loaded("imagick")) { fwrite(STDERR, "FAIL: imagick gone\n"); exit(1); }'; \
    rm -rf /var/lib/apt/lists/* /usr/local/bin/install-php-extensions
