# Environment passthrough (LOCI-030, spec §10.3) - the clear_env regression.
#
# ITS OWN FILE AND ITS OWN NAME BECAUSE THE FAILURE IS SILENT. With PHP-FPM's
# default of `clear_env = yes`, a worker is handed an empty environment: the
# container's variables are set, `docker inspect` shows them, `printenv` in the
# same container shows them, and env() inside a request still returns the
# default. Nothing crashes, nothing logs, every other assertion in this suite
# stays green, and the application quietly runs on fallback configuration -
# wrong database, wrong queue, wrong mailer. The image sets clear_env = no
# (§6.4) precisely to prevent that, and this is the only check that the setting
# survived into a running worker rather than merely into a config file.
#
# Asserted over HTTP on purpose. `docker compose exec fpm printenv` proves only
# that the container has the variable, which is true in the broken case too -
# the claim is that a PHP process SERVING A REQUEST can read it.

load helpers

setup_file() {
  require_smoke_env || return 1

  # The route is a Laravel route; without vendor/ it 500s and this suite would
  # report a clear_env failure that is really a missing install.
  ensure_app_installed || return 1

  http_get env_echo /env-echo
}

@test "the env-echo route answers at all" {
  # Separated from the value assertion so a 500 reports as a broken route rather
  # than as a passthrough failure. They have entirely different causes.
  local code
  code="$(http_code env_echo)"
  if [ "$code" != "200" ]; then
    echo "GET /env-echo returned $code" >&2
    dump_app_errors
  fi
  [ "$code" = "200" ]
}

@test "an env var set on the fpm container is visible to env() in the app (clear_env)" {
  # Exact equality, not a substring. A substring match would also pass on
  # "LARAOCI_SMOKE_VALUE=MISSING" if the expected value were ever empty, which
  # is exactly the failure being guarded against.
  [ "$(http_body env_echo)" = "LARAOCI_SMOKE_VALUE=${LARAOCI_SMOKE_VALUE}" ]
}

@test "the app did not fall back to the route's default" {
  local body
  body="$(http_body env_echo)"

  # THE PREFIX CHECK IS NOT REDUNDANT, and this was established by running the
  # regression rather than by reasoning about it. `clear_env = yes` was injected
  # into the pool and this case PASSED, because the response was Laravel's error
  # page and an error page trivially does not contain the word MISSING.
  #
  # The reason is worth recording: this stack supplies APP_KEY through the
  # environment too, so clearing the environment takes the key with it and the
  # app 500s in EncryptCookies before the route's env() call is ever reached.
  # The plan's predicted symptom - a 200 reporting MISSING - is what happens to
  # an app whose key comes from a .env file instead. Both are the same defect,
  # so this case now requires a real answer from the route before deciding
  # whether that answer is the fallback.
  [[ "$body" == LARAOCI_SMOKE_VALUE=* ]]
  [[ "$body" != *"MISSING"* ]]
}

@test "the asserted value is unique to this run" {
  # Guards the test itself rather than the image. LARAOCI_SMOKE_VALUE carries a
  # per-run nonce (run.sh) so that a container left over from an earlier run of
  # the SAME php version - answering on the same derived port - cannot satisfy
  # the assertion above. Without the nonce the expected string is identical
  # between runs and a stale stack passes silently, which is the same class of
  # bug this whole file exists to catch.
  [[ "$LARAOCI_SMOKE_VALUE" =~ ^laraoci-smoke-[0-9.]+-[0-9a-f]{12}$ ]]
}
