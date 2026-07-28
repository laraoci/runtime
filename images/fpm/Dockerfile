# syntax=docker/dockerfile:1

# LaraOCI fpm - PHP-FPM for Laravel, behind Nginx, Caddy or Traefik
# (spec §7.3, LOCI-023).
#
# NO SAPI INSTALLATION. `runtime` derives from the upstream -fpm variant (D18),
# so it already carries /usr/local/sbin/php-fpm, upstream's
# php-fpm.d/docker.conf and zz-docker.conf, and EXPOSE 9000. This image supplies
# a command and the correct stop signal, and later issues add the pool overlay
# (LOCI-024) and the healthcheck (LOCI-025). Nothing here re-declares what the
# base or the parent already set - a second copy is a second thing to drift, and
# tests/structure/fpm.yaml asserts the inherited values instead.
#
# EXPOSE is one of those: verified on the built parent, `docker image inspect`
# reports "ExposedPorts": {"9000/tcp": {}}. Re-declaring it here would add
# nothing and would imply this image opened the port.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
# The parent is a LaraOCI image, not the upstream php image. An ARG rather than
# a hardcoded FROM so that bin/build-chain.sh can point it at the ref it just
# built locally, and so M4 can pin it by digest the way BASE_DIGEST already pins
# the upstream base in images/runtime/Dockerfile.
ARG PARENT_REF=ghcr.io/laraoci/runtime:${PHP_VERSION}-${DEBIAN_RELEASE}
FROM ${PARENT_REF}

# ---------------------------------------------------------------------------
# THE STOP SIGNAL - the carry-forward note in images/runtime/Dockerfile, now
# discharged.
#
# php-fpm and the CLI images read the two signals in OPPOSITE ways:
#
#   php-fpm   SIGQUIT -> finish in-flight requests, then exit (graceful)
#             SIGTERM -> terminate immediately
#   cli/queue SIGTERM -> what pcntl traps for a graceful worker shutdown
#
# runtime sets SIGTERM because that is correct for cli, queue and scheduler,
# which is most of the graph. Without this line every fpm container inherits it
# and is killed mid-request on `docker stop`, on a rolling deploy, and on every
# pod eviction - a truncated response rather than a drained one, and invisible
# until it happens under load.
#
# The upstream -fpm image sets SIGQUIT for exactly this reason; this restores
# it. container-structure-test cannot assert a stop signal - its metadataTest
# schema has no such field, and a container cannot read its own - so the
# assertion lives in .github/workflows/build.yml against images.fpm.stopsignal
# in config/images.yml.
STOPSIGNAL SIGQUIT

# Exec form (§6.2), and bare `php-fpm` rather than a flag-laden invocation:
# daemonize = no and the log redirections already come from upstream's
# zz-docker.conf and docker.conf (§6.3), so every flag that might appear here
# would be a restatement of configuration the audit in tests/structure/fpm.yaml
# exists to protect.
#
# It reaches php-fpm through tini and laraoci-entrypoint, both inherited: tini
# is PID 1 (D9) and forwards the stop signal above, and the entrypoint renders
# the ini, classifies this as an FPM process for the preload gate (🧭 1, D22),
# and execs onward without leaving a wrapper in the process tree.
CMD ["php-fpm"]
