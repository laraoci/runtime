# LaraOCI runtime - the shared base layer for every LaraOCI image (spec §7.1, D2).
#
# Derives from the -fpm upstream variant (D18 / §3.4): it ships
# /usr/local/bin/php as well as /usr/local/sbin/php-fpm, which is the only
# arrangement that makes the single-rooted image graph implementable. A -cli
# base cannot gain FPM without recompiling PHP.
#
# OCI labels are NOT set here. They are applied by .github/workflows/build.yml
# (LOCI-019) so that source, revision, created, and the resolved base digest
# come from the build context rather than from a hand-edited file per image.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
FROM php:${PHP_VERSION}-fpm-${DEBIAN_RELEASE}
# Identity is passed in from config/images.yml (D8 / §6.1). A UID that silently
# differs between images is the failure D8 exists to prevent, so these have no
# second source of truth: the workflow reads images.yml and passes them here.
ARG USER_NAME=laravel
ARG USER_UID=1000
ARG USER_GID=1000

# ---------------------------------------------------------------------------
# RUN 2 - BOUNDARY: identity only. Kept out of the extension layer so that
# changing the UID does not invalidate an expensive rebuild.
#
# The base has www-data at 33 and nothing at 1000, but that is an observation,
# not a guarantee. A collision must fail the build - `|| true` here would ship
# an image whose UID silently differs from the contract.
#
# /var/www/html exists in the fpm base as www-data:www-data mode 1777. chown
# alone would leave it world-writable, so the mode is reset too.
#
# `useradd -l` (--no-log-init) skips lastlog/faillog initialisation. At UID 1000
# it changes nothing, but USER_UID is a build arg: without -l, a consumer
# building with a high UID gets a sparse lastlog expanded to gigabytes in the
# layer. Nothing in a container reads lastlog anyway.
RUN set -eux; \
    if getent group "${USER_GID}" >/dev/null; then \
      echo "FAIL: GID ${USER_GID} already exists: $(getent group "${USER_GID}")" >&2; exit 1; fi; \
    if getent passwd "${USER_UID}" >/dev/null; then \
      echo "FAIL: UID ${USER_UID} already exists: $(getent passwd "${USER_UID}")" >&2; exit 1; fi; \
    groupadd -g "${USER_GID}" "${USER_NAME}"; \
    useradd -l -u "${USER_UID}" -g "${USER_GID}" -m -s /bin/sh "${USER_NAME}"; \
    mkdir -p /var/www/html; \
    chown "${USER_UID}:${USER_GID}" /var/www/html; \
    chmod 0755 /var/www/html; \
    test "$(id -u "${USER_NAME}")" = "${USER_UID}"; \
    test "$(id -g "${USER_NAME}")" = "${USER_GID}"

WORKDIR /var/www/html

USER ${USER_NAME}
