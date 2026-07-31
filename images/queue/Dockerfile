# syntax=docker/dockerfile:1

# LaraOCI queue - a long-lived Laravel queue worker (spec §7.5, LOCI-032, D4).
#
# THREE LINES PAST `FROM`, and that is the whole build. `cli` already carries the
# extensions, the user, tini, the entrypoint, LARAOCI_DEFAULT_BINARY=php and the
# 512M/0 CLI ceilings; D4 says queue and scheduler are `FROM cli` plus a CMD,
# with room to diverge later. What this image adds is one env var and one
# command.
#
# WHAT IT DOES *NOT* ADD, each deliberately:
#
#   STOPSIGNAL   Inherited SIGTERM from runtime, and CORRECT here - the opposite
#                of fpm, which had to restore SIGQUIT. queue:work traps SIGTERM
#                through pcntl and finishes the job in hand. Re-declaring it
#                would pass every check while destroying the evidence that
#                inheritance works, so build.yml asserts it against
#                config/images.yml (absent key = SIGTERM) instead.
#   HEALTHCHECK  §7.5: a queue worker has no meaningful synchronous health
#                signal, and a naive one is worse than none. Documented
#                alternative: `queue:monitor` on a schedule, or Horizon.
#   USER/WORKDIR Inherited. This image never needs root.
#
# The graceful drain this image exists for depends on FOUR things, and only the
# last is here: pcntl+posix compiled in (runtime), STOPSIGNAL SIGTERM (runtime),
# tini forwarding the signal as PID 1 (D9, runtime), and queue:work being invoked
# so it actually traps (below). tests/smoke/queue-shutdown.bats is what proves
# all four are wired - a truncated job on a rolling deploy is invisible until it
# happens under load.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
# The parent is a LaraOCI image, not the upstream php image. Declared as an ARG
# rather than hardcoded into FROM so bin/build-chain.sh can point it at the ref
# it just built locally, and so the release path (M4) can pin it by digest.
ARG PARENT_REF=ghcr.io/laraoci/cli:${PHP_VERSION}-${DEBIAN_RELEASE}
FROM ${PARENT_REF}

# 🧭 1 / D29. The one image where preload on CLI pays for itself: a queue worker
# compiles once and then serves thousands of jobs from the warm segment, where a
# one-off `php artisan` builds the segment at start and destroys it at exit -
# which is why D22 gates preload on the SAPI everywhere else.
#
# INERT UNTIL THE OPERATOR NAMES THE SCRIPT. PHP_OPCACHE_PRELOAD is deliberately
# NOT defaulted here (🧭 1 option (a)): this image cannot know whether it has a
# vendor tree - bind-mount deployments and base-image consumers routinely do not
# - and §7.7 pairs preload with PHP_OPCACHE_MEMORY_CONSUMPTION=320 against the
# inherited default of 192, so preloading by default would either overrun a
# segment sized for no preload or raise opcache memory for every queue container
# whether or not it preloads. Turn it on with:
#
#   -e PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
#   -e PHP_OPCACHE_MEMORY_CONSUMPTION=320
ENV LARAOCI_PRELOAD_FORCE=1

# §7.5, exec form (§6.2). Every flag earns its place:
#
#   --no-interaction  a prompt in a container is a hung worker
#   --tries=3         bounded retries; a poison job reaches failed_jobs instead
#                     of looping forever, and a transient failure gets two more
#                     chances
#   --max-time=3600   bounds worker lifetime so leaks and stale state never
#                     accumulate; the container exits and is restarted cleanly
#   --rest=0.1        yields the CPU for 100 ms between jobs
#
# --timeout is deliberately absent: Laravel's 60 s default is the number the
# LOCI-039 warning is measured against - THE ORCHESTRATOR'S GRACE PERIOD MUST
# EXCEED IT. Docker's default grace is 10 s, which kills in-flight jobs on every
# deploy no matter how correct this image is. The image cannot fix that; the
# README says so.
CMD ["php", "artisan", "queue:work", \
     "--no-interaction", "--tries=3", "--max-time=3600", "--rest=0.1"]
