# The request path, end to end (LOCI-029, spec §10.2 steps 1-3).
#
# builder installs the dependencies -> cli migrates and reports -> fpm serves the
# result through a real nginx FastCGI hop. Every other suite in this directory
# asserts one property of one image; this one asserts that the three of them
# compose into a working Laravel deployment, which is the only claim the images
# actually make to a user.
#
# Driven by tests/smoke/run.sh, which owns the stack and the teardown. Running
# this file directly fails in setup_file with a message saying so.
#
# Deliberately does NOT call ensure_app_installed: installing the application is
# the thing this suite asserts, so it runs the commands itself.

load helpers

setup_file() {
  require_smoke_env || return 1

  # THE STEPS RUN ONCE, HERE, IN ORDER, AND THEIR RESULTS ARE CAPTURED. Two
  # reasons. `composer install` takes the better part of a minute, so a case
  # that re-ran it per assertion would turn a two-minute suite into a ten-minute
  # one. More importantly the steps are ORDERED - npm run build cannot precede
  # npm ci, migrate cannot precede composer install - and bats gives no ordering
  # guarantee between cases.
  #
  # capture() deliberately does NOT fail setup_file on a non-zero step. A failed
  # setup_file aborts the whole file with one opaque error; letting each step
  # record its status and having the matching case assert on it means a broken
  # `npm run build` is reported as a failing build assertion, with its output,
  # while everything downstream still reports too.
  capture composer_install compose run --rm builder \
    composer install --no-interaction --no-progress
  capture npm_ci compose run --rm builder npm ci --no-audit --no-fund
  capture npm_build compose run --rm builder npm run build

  capture vendor_present compose run --rm cli test -f vendor/autoload.php
  capture manifest_present compose run --rm cli test -f public/build/manifest.json

  capture migrate compose run --rm cli \
    php artisan migrate --force --no-interaction
  capture about compose run --rm cli php artisan about

  http_get root /

  # The hashed filename is read out of the response rather than out of the
  # manifest on disk: what is being asserted is that the name the APPLICATION
  # reports is the name nginx can actually serve. Reading the manifest here
  # would test vite against itself and let a mismatch through.
  local asset
  asset="$(sed -n 's/.*asset=\([^ ]*\).*/\1/p' "$BATS_FILE_TMPDIR/root.body")"
  printf '%s\n' "$asset" >"$BATS_FILE_TMPDIR/asset.name"
  if [ -n "$asset" ]; then
    http_get asset "/build/$asset"
  fi

  # Straight to the pool over FastCGI, bypassing nginx entirely - /fpm-ping is
  # answered by the FPM master itself and never reaches PHP, so this stays
  # meaningful even when the application is broken.
  capture ping compose exec -T fpm sh -c \
    'SCRIPT_NAME=/fpm-ping SCRIPT_FILENAME=/fpm-ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000'
}

@test "builder: composer install resolves the lock file" {
  assert_step_ok composer_install
}

@test "builder: composer install produced a vendor tree" {
  assert_step_ok vendor_present
}

@test "builder: npm ci installs from the committed lock file" {
  # `ci`, never `install` - it is the command that fails when package.json and
  # package-lock.json disagree, which is the whole reason the lock is committed.
  assert_step_ok npm_ci
}

@test "builder: npm run build produced a vite manifest" {
  assert_step_ok npm_build
  assert_step_ok manifest_present
}

@test "cli: artisan migrate runs against sqlite" {
  assert_step_ok migrate
  [[ "$(step_output migrate)" == *"DONE"* ]]
}

@test "cli: artisan about reports the environment" {
  assert_step_ok about
  [[ "$(step_output about)" == *"Environment"* ]]
}

@test "fpm behind nginx serves / with 200" {
  local code
  code="$(http_code root)"
  if [ "$code" != "200" ]; then
    echo "GET / returned $code" >&2
    dump_app_errors
  fi
  [ "$code" = "200" ]
}

@test "fpm behind nginx serves the application's own marker" {
  [[ "$(http_body root)" == *"laraoci-fixture-ok"* ]]
}

@test "the served page names the asset the build produced" {
  # A 200 carrying the marker proves PHP ran; it does NOT prove the build did.
  # The route reads the hashed name out of vite's manifest, so its presence in
  # the response is what distinguishes "the app answered" from "the app was
  # built and then answered".
  local asset
  asset="$(cat "$BATS_FILE_TMPDIR/asset.name")"
  [ -n "$asset" ]
  [[ "$asset" == assets/* ]]
  [[ "$asset" == *.js ]]
}

@test "nginx serves the hashed asset the application named" {
  # The end of the chain: vite wrote it, the manifest recorded it, the app
  # reported it, and nginx can hand it to a browser off the shared volume.
  # Asserted rather than assumed - the two containers mount the same volume at
  # the same path precisely so this holds, and nothing else checks it.
  [ -f "$BATS_FILE_TMPDIR/asset.code" ]
  [ "$(http_code asset)" = "200" ]
}

@test "fpm answers its own ping without touching PHP" {
  assert_step_ok ping
  [[ "$(step_output ping)" == *"pong"* ]]
}
