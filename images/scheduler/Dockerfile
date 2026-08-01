# syntax=docker/dockerfile:1

# LaraOCI scheduler - Laravel's scheduler as one foreground process
# (spec §7.6, LOCI-033, D4, D10).
#
# TWO LINES PAST `FROM`, and the image is genuinely trivial - which is the trap.
# Its correctness is a property of HOW MANY YOU RUN, not of what is in it: two
# scheduler replicas double-fire every task, and no HEALTHCHECK, no ENV and no
# CMD can prevent that, because an image cannot know how many copies of itself
# are running. That constraint is documented in the README (LOCI-039) and
# proven-in-the-happy-path by tests/smoke/scheduler-single-fire.bats; it is
# deliberately NOT "solved" here.
#
# NOT ADDED, deliberately:
#
#   LARAOCI_PRELOAD_FORCE  queue's, and only queue's (🧭 1 / D29). This process
#                          sleeps between minute boundaries and forks a
#                          SHORT-LIVED `schedule:run` child; a preload segment in
#                          the parent buys the child nothing and is paid for on
#                          every start. tests/structure/scheduler.yaml asserts
#                          the flag's absence, because "copy queue and change the
#                          CMD" would ship it by accident.
#   STOPSIGNAL             Inherited SIGTERM, correct, asserted by build.yml
#                          against config/images.yml rather than re-declared.
#   HEALTHCHECK            §7.6. There is no synchronous health signal here
#                          either, and a naive one would be worse than none.
ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie
ARG PARENT_REF=ghcr.io/laraoci/cli:${PHP_VERSION}-${DEBIAN_RELEASE}
FROM ${PARENT_REF}

# D10: `schedule:work`, not cron. One foreground process that stays alive and
# dispatches `schedule:run` on each minute boundary - so the logs go to stdout
# like every other container, there is no cron daemon to reap, and the process
# tree is one deep. --no-interaction because a prompt in a container is a hang.
#
# Sub-minute tasks (Laravel 11+) are handled by the same loop, so nothing here
# needs to know about them.
CMD ["php", "artisan", "schedule:work", "--no-interaction"]
