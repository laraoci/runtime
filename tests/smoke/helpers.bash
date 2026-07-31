# Shared plumbing for the tests/smoke/*.bats suites. Loaded with `load helpers`.
#
# WHY A SHARED FILE AND NOT THREE COPIES. Every suite needs the same four
# things - the compose handle, a way to run a step without aborting the file, a
# way to make an HTTP request, and the guarantee that the application is
# installed. Copying those into each suite would mean a fix to any of them
# landing in one file and not the others, and the ones that were missed would
# keep reporting green.
#
# NOTHING HERE ASSERTS. These are mechanisms; the claims live in the suites.

# The stack belongs to run.sh, which exports these. There is deliberately no
# fallback: a default project name would silently point a suite at some other
# stack on the machine and assert against it.
require_smoke_env() {
  local var
  for var in LARAOCI_SMOKE_PROJECT LARAOCI_SMOKE_COMPOSE_FILE LARAOCI_SMOKE_URL; do
    if [ -z "${!var:-}" ]; then
      echo "$var is unset - run this through tests/smoke/run.sh, not directly" >&2
      return 1
    fi
  done
}

# Both flags are required. --project-name alone is enough for `down`, which
# rebuilds the project from the running containers' labels, but not for `run` or
# `exec`, which have to resolve a service definition out of the file.
compose() {
  docker compose \
    --project-name "$LARAOCI_SMOKE_PROJECT" \
    --file "$LARAOCI_SMOKE_COMPOSE_FILE" "$@"
}

# Run a step, keeping its combined output and exit status for the cases to
# assert on. The `|| status=$?` is what stops a non-zero step from aborting
# setup_file: a failed setup_file reports one opaque error for the whole file,
# where a recorded status lets the matching case report the real failure with
# its output while every other case still runs.
capture() {
  local name="$1"
  shift
  local status=0
  "$@" >"$BATS_FILE_TMPDIR/$name.out" 2>&1 || status=$?
  printf '%s\n' "$status" >"$BATS_FILE_TMPDIR/$name.status"
}

step_status() { cat "$BATS_FILE_TMPDIR/$1.status"; }
step_output() { cat "$BATS_FILE_TMPDIR/$1.out"; }

# Print the step's output on failure. Without it a red case says only
# "expected 0, got 1" and the reader has to reproduce the stack by hand.
assert_step_ok() {
  local name="$1"
  local status
  status="$(step_status "$name")"
  if [ "$status" -ne 0 ]; then
    echo "step '$name' exited $status:" >&2
    step_output "$name" >&2
  fi
  [ "$status" -eq 0 ]
}

# Body and status code, kept separately so a case can assert on either without
# re-issuing the request.
http_get() {
  local name="$1" path="$2"
  curl -sS --max-time 30 \
    -o "$BATS_FILE_TMPDIR/$name.body" \
    -w '%{http_code}' \
    "$LARAOCI_SMOKE_URL$path" >"$BATS_FILE_TMPDIR/$name.code" 2>&1 || true
}

http_code() { cat "$BATS_FILE_TMPDIR/$1.code"; }
# Command substitution strips the trailing newline, which is what makes an
# exact `==` comparison against an expected value work.
http_body() { cat "$BATS_FILE_TMPDIR/$1.body"; }

# Laravel cannot boot without vendor/, so every suite that makes a request needs
# it. WHICH suite installs it is not a contract: run.sh hands bats a glob, so the
# files run in alphabetical order, and `env-passthrough.bats` sorts before
# `request-path.bats` - the suite that owns the install assertion runs SECOND.
#
# Rather than encode an ordering nobody can see from the filenames, each suite
# asks for what it needs and this is idempotent. request-path.bats deliberately
# does NOT call it: that suite's job is to assert the install works, so it runs
# the command itself and checks the result.
ensure_app_installed() {
  if compose run --rm cli test -f vendor/autoload.php >/dev/null 2>&1; then
    return 0
  fi

  local out
  out="$(compose run --rm builder composer install --no-interaction --no-progress 2>&1)" || {
    echo "could not install the application - no route can answer without it:" >&2
    echo "$out" >&2
    return 1
  }
}

# The application's own error log, which is what a reader actually needs when a
# route returns 500 - Laravel's error page is ~15 KB of inline CSS wrapped
# around the words "Server Error". Only ever called on a failure path.
dump_app_errors() {
  echo "last application errors:" >&2
  compose run --rm cli sh -c \
    "grep -o 'ERROR: [^{]*' storage/logs/laravel.log | tail -5" >&2 2>/dev/null ||
    echo "  (no ERROR lines in storage/logs/laravel.log)" >&2
}

# The fully-qualified reference for one image of the CURRENT leg. Needed by the
# suites that run a container OUTSIDE the compose stack - LOCI-038's empty-vendor
# case is precisely "this image with no application volume at all", which cannot
# be expressed as a compose service because the service exists to mount one.
#
# No fallbacks, for the same reason require_smoke_env has none: a default here
# would silently test some other image on the machine.
image_ref() {
  local var
  for var in LARAOCI_REGISTRY LARAOCI_PHP LARAOCI_DEBIAN; do
    if [ -z "${!var:-}" ]; then
      echo "$var is unset - run this through tests/smoke/run.sh, not directly" >&2
      return 1
    fi
  done
  printf '%s/%s:%s-%s\n' \
    "$LARAOCI_REGISTRY" "$1" "$LARAOCI_PHP" "$LARAOCI_DEBIAN"
}

# The queue suite needs the `jobs` table and the scheduler suite needs a bootable
# application, and NEITHER can rely on request-path.bats having migrated first:
# run.sh hands bats a glob, so files run in alphabetical order and
# `queue-shutdown.bats` sorts BEFORE `request-path.bats`. Rather than encode an
# ordering nobody can see from the filenames - the reasoning ensure_app_installed
# already applies to vendor/ - each suite asks for what it needs and this is
# idempotent: `migrate --force` on an up-to-date database is a no-op.
ensure_app_migrated() {
  ensure_app_installed || return 1

  local out
  out="$(compose run --rm cli php artisan migrate --force --no-interaction 2>&1)" || {
    echo "could not migrate the application - the queue has no jobs table without it:" >&2
    echo "$out" >&2
    return 1
  }
}
