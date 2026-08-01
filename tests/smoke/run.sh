#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=bin/lib/common.sh
. "$REPO_ROOT/bin/lib/common.sh"

require_mikefarah_yq

# The smoke harness (LOCI-028). Builds the three M2 images for one PHP version,
# seeds a named volume from tests/fixtures/app, brings up fpm + nginx, runs every
# tests/smoke/*.bats file against the running stack, and tears the whole thing
# down unconditionally.
#
# Tasks 11-13 add .bats files and NOTHING ELSE. If adding a smoke assertion ever
# requires editing this script, the seam is in the wrong place.
#
# usage: tests/smoke/run.sh --php 8.4 [--keep]

php=""
keep=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php)
      require_arg "$1" "${2:-}"
      php="$2"
      shift 2
      ;;
    # Leave the stack running for inspection. The teardown message still prints
    # the exact command to remove it, because a leaked stack that nobody knows
    # how to remove is the same problem as a leaked stack.
    --keep)
      keep=1
      shift
      ;;
    -h | --help)
      echo "usage: run.sh --php VERSION [--keep]" >&2
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$php" ]]; then
  echo "error: --php is required" >&2
  exit 2
fi

cd "$REPO_ROOT"

# Resolve the version against config/images.yml rather than trusting the flag. A
# typo would otherwise surface as a docker pull of a tag that does not exist,
# several minutes and one confusing error message later.
#
# strenv, not interpolation: this is the ONE query in the repository that takes
# its value straight from the command line, and it runs BEFORE anything has
# validated the value's shape. bin/build-chain.sh applies the same reasoning to
# --image and --php.
status="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].status // "absent"' config/images.yml)"
case "$status" in
  supported) ;;
  deprecated)
    echo "error: PHP $php is deprecated in config/images.yml; the smoke suite covers supported versions only" >&2
    exit 2
    ;;
  *)
    echo "error: PHP $php is not in config/images.yml" >&2
    exit 2
    ;;
esac

registry="$("$YQ" -r '.defaults.registry' config/images.yml)"
# The per-version Debian override is the trixie-transition mechanism; honouring
# it here keeps the smoke tags identical to the ones bin/build-chain.sh produces.
debian="$(PHP="$php" "$YQ" -r '.php[strenv(PHP)].debian // .defaults.debian' config/images.yml)"

# COMPOSE PROJECT NAMES CANNOT CONTAIN A DOT. Compose rejects
# `laraoci-smoke-8.4` with "must consist only of lowercase alphanumeric
# characters, hyphens, and underscores", so the separator is stripped rather
# than the version being passed through verbatim.
project="laraoci-smoke-${php//./}"

# One port per version, derived rather than fixed, so `run.sh --php 8.3` and
# `run.sh --php 8.4` can run at the same time on one machine. 8.3 -> 18083.
port="180${php//./}"

export LARAOCI_REGISTRY="$registry"
export LARAOCI_PHP="$php"
export LARAOCI_DEBIAN="$debian"
export LARAOCI_SMOKE_PORT="$port"
# The value LOCI-030 looks for, GENERATED PER RUN. The prefix carries the php
# version so a container from another leg answering on this port produces a
# mismatch rather than a false pass; the nonce covers the case the prefix cannot
# - a stale container from a PREVIOUS run of the SAME version, which would
# otherwise carry a byte-identical value and satisfy the assertion while proving
# nothing about the stack that was just built.
#
# tests/smoke/env-passthrough.bats asserts this shape, so the two change
# together.
nonce="$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
export LARAOCI_SMOKE_VALUE="laraoci-smoke-${php}-${nonce}"

compose() {
  docker compose --project-name "$project" --file "$SCRIPT_DIR/compose.yml" "$@"
}

# THE TRAP IS INSTALLED BEFORE ANYTHING IS CREATED, not after `up`. A harness
# that leaks a container or a volume on the failure path is a harness that gets
# disabled within a month, and the failure path includes a Ctrl-C during the
# image build as much as a red test.
#
# `down -v` is what removes the named volume; without it the next run seeds a
# volume that still holds the previous run's vendor/ and public/build/, and a
# broken build would pass by reusing the last good one. --remove-orphans catches
# services deleted from compose.yml since the last run.
teardown() {
  local code=$?
  if ((keep)); then
    echo
    echo "smoke: --keep, leaving the stack up. Remove it with:"
    # NO --file, deliberately. compose.yml guards every variable with `:?`, so
    # `docker compose -f tests/smoke/compose.yml down` fails with "required
    # variable LARAOCI_REGISTRY is missing a value" for anyone who did not
    # export what run.sh exports - which is everyone reading this message. Given
    # only a project name, compose reconstructs the project from the running
    # containers' own labels and needs no file and no environment at all.
    echo "  docker compose -p $project down --volumes --remove-orphans"
    return "$code"
  fi
  echo
  echo "smoke: tearing down $project"
  compose down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || true
  return "$code"
}
trap teardown EXIT

echo "smoke: PHP $php ($debian), project $project, http://127.0.0.1:$port"

# A previous run interrupted hard enough to skip its own trap (SIGKILL, a
# crashed terminal) leaves a stack behind that would make `up` reuse a stale
# volume. Clearing first costs nothing when there is nothing to clear.
compose down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || true

echo "smoke: building images"
# EVERY laraoci image compose.yml can resolve, not just the M2 three. queue and
# scheduler are declared there with `image:` and no `build:` key, so a missing tag
# is not a build error - compose PULLS it, and nothing is published until M4
# (D27). The leg then dies on "manifest unknown", which reads like a registry
# outage; it passed on the machine where the M3 images had been built by hand.
#
# ONE LINE, ONE ARRAY: tests/unit/smoke-harness.bats parses this declaration and
# fails if compose.yml resolves an image that is missing from it, so a service
# added there without a build here goes red in the unit suite rather than four
# minutes into a smoke leg.
smoke_images=(cli fpm builder queue scheduler)
for image in "${smoke_images[@]}"; do
  bin/build-chain.sh --image "$image" --php "$php"
done

# THE TAG THE SUITES WILL USE IS THE TAG THIS RUN BUILT. bin/structure-test.sh:130
# asserts the same thing for the same reason: compose resolves a tag it cannot
# find by pulling, so a registry/debian override that made build-chain.sh produce
# a DIFFERENT reference would surface as a pull error inside a .bats file instead
# of here, next to the build that was supposed to produce it.
for image in "${smoke_images[@]}"; do
  ref="$registry/$image:$php-$debian"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    echo "error: $ref is not in the local daemon after bin/build-chain.sh" >&2
    echo "       the smoke suites resolve images by tag and would PULL this one" >&2
    exit 1
  fi
done

echo "smoke: seeding the app volume from tests/fixtures/app"
compose run --rm seed

echo "smoke: starting fpm and nginx"
# --wait blocks until every service is healthy or its start_period expires, so an
# fpm image whose LOCI-025 healthcheck never goes green fails HERE, with the
# service named, rather than as a pile of connection-refused errors inside the
# .bats files.
compose up --detach --wait

# The .bats files receive everything they need to talk to the stack through the
# environment, so none of them hardcodes a project name, a port or a compose
# path. LARAOCI_COMPOSE is a full command line on purpose: `eval "$LARAOCI_COMPOSE
# run --rm cli php artisan migrate"` is all a test needs.
export LARAOCI_SMOKE_PROJECT="$project"
export LARAOCI_SMOKE_COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
export LARAOCI_COMPOSE="docker compose --project-name $project --file $SCRIPT_DIR/compose.yml"
export LARAOCI_SMOKE_URL="http://127.0.0.1:$port"

shopt -s nullglob
suites=("$SCRIPT_DIR"/*.bats)
shopt -u nullglob

if ((${#suites[@]} == 0)); then
  echo "smoke: no tests/smoke/*.bats files yet - stack came up and will now be torn down"
  exit 0
fi

echo "smoke: running ${#suites[@]} suite(s)"
bats_bin="$(bin/fetch-tools.sh --path bats)"
"$bats_bin" "${suites[@]}"
