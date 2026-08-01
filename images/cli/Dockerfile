# syntax=docker/dockerfile:1

# LaraOCI cli - artisan, migrations, tinker, one-off tasks (spec §7.2, LOCI-022),
# and the parent of queue and scheduler (D4).
#
# There is nothing to install. runtime carries the extensions, the user, tini,
# the ImageMagick policy and the entrypoint; this image differs from it in
# exactly three ways - which binary a dash-first argument means, the two §6.4
# values that are per-SAPI, and the command.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
# The parent is a LaraOCI image, not the upstream php image. Declared as an ARG
# rather than hardcoded into FROM so the release path (M4) can pin it by digest
# the way BASE_DIGEST already pins the upstream base in images/runtime.
ARG PARENT_REF=ghcr.io/laraoci/runtime:${PHP_VERSION}-${DEBIAN_RELEASE}
FROM ${PARENT_REF}

# 🧭 1. The single source of truth for "what does a dash-first argument mean on
# this image". /usr/local/bin/laraoci-entrypoint reads it for BOTH halves of the
# problem: it prepends this binary itself (so upstream's docker-php-entrypoint,
# which would prepend php-fpm, never sees a dash-first argv and can never fire),
# and it classifies the launched process from the result (so a dash-invoked
# artisan command is not mistaken for FPM and does not enable opcache.preload -
# D14/D22). queue and scheduler inherit this; they are CLI processes too.
ENV LARAOCI_DEFAULT_BINARY=php

# §6.4, the cli column. A CLI process is not serving an HTTP request, so FPM's
# request ceiling is the wrong default: `artisan migrate` on a large table must
# not die at 30 seconds, and `artisan tinker` should not die at 256 MB.
ENV PHP_MEMORY_LIMIT=512M \
    PHP_MAX_EXECUTION_TIME=0

# RE-RENDER, because an ENV alone does not reach the file. runtime rendered
# zz-laraoci.ini at build time from ITS values, so without this the shipped file
# says 256M / 30 while this image declares 512M / 0 - and queue and scheduler
# inherit that file. Normally invisible (the entrypoint overwrites it at start),
# it is the whole configuration on the one path README.md:56 documents: a
# read-only root filesystem, where nothing re-renders.
#
# Same one-line idiom as images/fpm/Dockerfile:114, and it runs as `laravel`
# (inherited from runtime) against a file pre-created with that ownership.
RUN /usr/local/bin/laraoci-entrypoint true

CMD ["php", "artisan", "list"]
