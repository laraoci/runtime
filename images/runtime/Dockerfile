# LaraOCI runtime - the shared base layer for every LaraOCI image.
#
# Derives from the -fpm upstream variant: it ships
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
