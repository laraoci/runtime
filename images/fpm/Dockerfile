# syntax=docker/dockerfile:1

# LaraOCI fpm - PHP-FPM for Laravel, behind Nginx, Caddy or Traefik
# (spec §7.3, LOCI-023).
#
# NO SAPI INSTALLATION. `runtime` derives from the upstream -fpm variant (D18),
# so it already carries /usr/local/sbin/php-fpm, upstream's
# php-fpm.d/docker.conf and zz-docker.conf, and EXPOSE 9000. This image supplies
# a command, the correct stop signal and an ADDITIVE pool overlay (LOCI-024);
# the healthcheck (LOCI-025) follows. Nothing here re-declares what the base or
# the parent already set - a second copy is a second thing to drift, and
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

# The identity D8 fixes. Re-declared after FROM because ARGs do not cross a
# stage boundary, and needed here by RUN 1 - which pre-creates the rendered pool
# file with this ownership and checks the template agrees about the name.
ARG USER_NAME=laravel
ARG USER_UID=1000
ARG USER_GID=1000

# §6.4, the fpm-only rows. The pool template references every one of them and
# laraoci-entrypoint refuses to render a template whose variables are unset or
# empty, so an omission here is a loud start-up failure rather than a blank
# directive that php-fpm silently accepts.
#
# They live on the image rather than in the template's text so that a consumer
# can retune the pool with `-e PHP_FPM_MAX_CHILDREN=40` - the whole reason the
# pool is rendered at start rather than shipped as a static file.
#
# PHP_FPM_PROCESS_CONTROL_TIMEOUT is the one that makes STOPSIGNAL SIGQUIT
# below do anything at all - see the template's own [global] block for the
# measurements. It is a ceiling, not a delay: an idle container still stops in
# ~0.2s. 10s matches Docker's default stop grace, and a consumer who raises it
# must raise the orchestrator's grace period to match.
ENV PHP_FPM_PM=dynamic \
    PHP_FPM_MAX_CHILDREN=20 \
    PHP_FPM_START_SERVERS=4 \
    PHP_FPM_MIN_SPARE_SERVERS=2 \
    PHP_FPM_MAX_SPARE_SERVERS=6 \
    PHP_FPM_MAX_REQUESTS=500 \
    PHP_FPM_PROCESS_CONTROL_TIMEOUT=10s

COPY --chmod=0644 config/php/zz-laraoci-fpm.conf.template /usr/local/share/laraoci/templates/

# ---------------------------------------------------------------------------
# RUN 1 - root work.
#
# libfcgi-bin is 41 KB, plus 92 KB for libfcgi0t64 - measured with dpkg-query,
# against the ~200 KB §7.3 estimates. It exists solely for the HEALTHCHECK; it
# lands here and not in runtime because no other image has a socket to ping.
#
# The rendered pool file is pre-created with laravel ownership for the same
# reason runtime pre-creates the two ini files: php-fpm.d stays root-owned and
# the entrypoint gets write access to exactly one file in it, not to the
# directory. Without it the render fails soft - render() reads a target it
# cannot open as "not writable", warns, and returns 0 - so the container would
# start with no pool overlay and no error.
#
# The template's user name is verified against USER_NAME rather than templated
# through an env var. Rendering it would put a LARAOCI_USER variable into the
# public contract that looks overridable and is not: changing it would not
# change USER, so the pool would name a user the master cannot become. A build
# with a different USER_NAME must fail loudly here instead.
USER root
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libfcgi-bin; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /usr/bin/cgi-fcgi; \
    grep -q "^user = ${USER_NAME}\$" /usr/local/share/laraoci/templates/zz-laraoci-fpm.conf.template; \
    grep -q "^group = ${USER_NAME}\$" /usr/local/share/laraoci/templates/zz-laraoci-fpm.conf.template; \
    install -o "${USER_UID}" -g "${USER_GID}" -m 0644 /dev/null \
      /usr/local/etc/php-fpm.d/zz-laraoci.conf

USER ${USER_NAME}

# ---------------------------------------------------------------------------
# RUN 2 - render and verify, as ${USER_NAME}, exactly as the container will.
#
# Rendering at build time by invoking the real entrypoint (runtime's RUN 4
# idiom, no second copy of the logic) means a template that cannot render fails
# the BUILD, an image started with --entrypoint still has a valid pool, and
# `php-fpm -tt` in the structure tests has something to read.
#
# php-fpm -tt is the verification: it parses the whole php-fpm.d/*.conf
# concatenation in glob order, so it proves the additive file landed in [www]
# and that upstream's directives survived - the trap 2 assertion, made at build
# time as well as in tests/structure/fpm.yaml.
#
# The four upstream directives are in the list for a reason: this is the first
# image to add a file to that glob, and the failure mode of getting the [www]
# header wrong is not a parse error but a silent reassignment of these values
# into whichever section was open.
#
# process_control_timeout is in the list for the opposite reason: it is the one
# directive here that belongs to [global] rather than [www], so it is the canary
# for our two section headers being the wrong way round. The trailing 's' is
# part of the assertion - php-fpm echoes the suffix verbatim rather than
# normalising it, and without it the grep would match 10m just as happily.
RUN set -eux; \
    /usr/local/bin/laraoci-entrypoint true; \
    php-fpm -tt >/tmp/fpm-tt.log 2>&1; \
    for d in \
      'user = laravel' \
      'group = laravel' \
      'pm.max_children = 20' \
      'pm.max_requests = 500' \
      'ping.path = /fpm-ping' \
      'ping.response = pong' \
      'pm.status_path = /fpm-status' \
      'process_control_timeout = 10s' \
      'clear_env = no' \
      'daemonize = no' \
      'catch_workers_output = yes' \
      'decorate_workers_output = no'; do \
      if ! grep -q "$d" /tmp/fpm-tt.log; then \
        echo "FAIL: php-fpm -tt does not report '$d'" >&2; cat /tmp/fpm-tt.log >&2; exit 1; \
      fi; \
    done; \
    rm -f /tmp/fpm-tt.log

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

# cgi-fcgi speaks FastCGI straight to the pool, so the check exercises the exact
# socket Nginx will use rather than a side channel. 15 s start-period covers the
# pool warming up; three failures at a 10 s interval mark it unhealthy in ~30 s,
# which is inside a typical orchestrator's patience and outside a GC pause.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD ["sh", "-c", "SCRIPT_NAME=/fpm-ping SCRIPT_FILENAME=/fpm-ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 | grep -q '^pong'"]

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
