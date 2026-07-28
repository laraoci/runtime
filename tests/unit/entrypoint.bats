setup() {
  command -v envsubst >/dev/null || skip "envsubst (gettext-base) is not installed"

  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/templates" "$TMP/php/conf.d" "$TMP/stub"

  export LARAOCI_TEMPLATE_DIR="$TMP/templates"
  export PHP_INI_DIR="$TMP/php"

  # Our entrypoint execs `docker-php-entrypoint` by name, so PATH resolution
  # picks this stub up exactly as it picks up the real one in the image.
  cat >"$TMP/stub/docker-php-entrypoint" <<'STUB'
#!/bin/sh
echo "handoff: $*"
STUB
  chmod +x "$TMP/stub/docker-php-entrypoint"
  PATH="$TMP/stub:$PATH"
  export PATH

  # A template shaped like the real one, plus the two things bare envsubst
  # would destroy: FPM's built-in $pool and an unrelated $VAR.
  cat >"$TMP/templates/zz-laraoci.ini.template" <<'TPL'
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
; pool = $pool
; untouched = $NOT_MINE
TPL

  export PHP_MEMORY_LIMIT=256M
  export PHP_MAX_EXECUTION_TIME=30
  unset PHP_OPCACHE_PRELOAD LARAOCI_PRELOAD_FORCE || true
}

teardown() {
  rm -rf "$TMP"
}

@test "entrypoint: renders the ini from the environment" {
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *"memory_limit = 256M"* ]]
  [[ "$output" == *"max_execution_time = 30"* ]]
}

@test "entrypoint: an override reaches the rendered ini" {
  PHP_MEMORY_LIMIT=1024M run bin/entrypoint.sh php -v
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *"memory_limit = 1024M"* ]]
}

@test "entrypoint: bare \$pool and unrelated \$VARs survive (trap 2)" {
  export NOT_MINE=clobbered
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *'; pool = $pool'* ]]
  [[ "$output" == *'; untouched = $NOT_MINE'* ]]
}

@test "entrypoint: an unset required variable is fatal" {
  unset PHP_MAX_EXECUTION_TIME
  run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"PHP_MAX_EXECUTION_TIME is unset"* ]]
}

@test "entrypoint: an empty required variable is fatal" {
  export PHP_MEMORY_LIMIT=""
  run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"PHP_MEMORY_LIMIT is empty"* ]]
}

@test "entrypoint: hands off to docker-php-entrypoint with the original arguments" {
  run bin/entrypoint.sh php -r 'echo 1;'
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff: php -r echo 1;"* ]]
}

@test "entrypoint: preload is ignored for a one-off CLI command (🧭 4)" {
  export PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
  run bin/entrypoint.sh php artisan migrate
  [ "$status" -eq 0 ]
  [[ "$output" == *"not an FPM process"* ]]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [ -z "$output" ]
}

@test "entrypoint: preload is enabled for php-fpm" {
  export PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
  run bin/entrypoint.sh php-fpm
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [[ "$output" == "opcache.preload = /usr/local/share/laraoci/preload.php" ]]
}

@test "entrypoint: LARAOCI_PRELOAD_FORCE opts a CLI worker in" {
  export PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
  export LARAOCI_PRELOAD_FORCE=1
  run bin/entrypoint.sh php artisan queue:work
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [[ "$output" == *"opcache.preload = "* ]]
}

@test "entrypoint: a stale preload directive is cleared on the next start" {
  echo 'opcache.preload = /stale.php' >"$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  run bin/entrypoint.sh php-fpm
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [ -z "$output" ]
}

@test "entrypoint: an unwritable target warns and continues" {
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores file permissions"
  echo 'memory_limit = 999M' >"$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  chmod 0444 "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"not writable"* ]]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *"999M"* ]]
}

@test "entrypoint: a newline in a required value is fatal (L3)" {
  # Otherwise anyone who can set one PHP_* variable can append arbitrary
  # directives - auto_prepend_file, disable_functions - to the rendered ini.
  PHP_MEMORY_LIMIT="$(printf '256M\nauto_prepend_file = /tmp/pwn.php')"
  export PHP_MEMORY_LIMIT
  run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-printable"* ]]
  [[ "$output" == *"PHP_MEMORY_LIMIT"* ]]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" != *"auto_prepend_file"* ]]
}

@test "entrypoint: a carriage return in a required value is fatal (L3)" {
  PHP_MEMORY_LIMIT="$(printf '256M\rx')"
  export PHP_MEMORY_LIMIT
  run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-printable"* ]]
}

@test "entrypoint: ordinary values are still accepted (L3 regression guard)" {
  export PHP_MEMORY_LIMIT=1024M
  export PHP_MAX_EXECUTION_TIME=0
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *"memory_limit = 1024M"* ]]
  [[ "$output" == *"max_execution_time = 0"* ]]
}

@test "entrypoint: no temp file is left behind (R5)" {
  before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
  [ "$after" -le "$before" ]
}

@test "entrypoint: a dash-first argument prepends the image's default binary (🧭 1)" {
  export LARAOCI_DEFAULT_BINARY=php
  run bin/entrypoint.sh -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff: php -v"* ]]
}

@test "entrypoint: a dash-first argument on an fpm image still means php-fpm (🧭 1)" {
  export LARAOCI_DEFAULT_BINARY=php-fpm
  run bin/entrypoint.sh -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff: php-fpm -v"* ]]
}

@test "entrypoint: an unset default binary behaves exactly as before (🧭 1)" {
  unset LARAOCI_DEFAULT_BINARY
  run bin/entrypoint.sh -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff: php-fpm -v"* ]]
}

@test "entrypoint: a dash-invoked CLI command does not enable preload (🧭 1, D22)" {
  export LARAOCI_DEFAULT_BINARY=php
  export PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
  run bin/entrypoint.sh -r 'echo 1;'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not an FPM process"* ]]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [ -z "$output" ]
}

@test "entrypoint: a dash-invoked fpm command still enables preload (🧭 1)" {
  export LARAOCI_DEFAULT_BINARY=php-fpm
  export PHP_OPCACHE_PRELOAD=/usr/local/share/laraoci/preload.php
  run bin/entrypoint.sh --nodaemonize
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [[ "$output" == "opcache.preload = /usr/local/share/laraoci/preload.php" ]]
}

@test "entrypoint: the fpm pool is rendered when its template ships" {
  export LARAOCI_FPM_CONF_D="$TMP/php-fpm.d"
  mkdir -p "$LARAOCI_FPM_CONF_D"
  cat >"$TMP/templates/zz-laraoci-fpm.conf.template" <<'TPL'
[www]
pm = ${PHP_FPM_PM}
pm.max_children = ${PHP_FPM_MAX_CHILDREN}
TPL
  export PHP_FPM_PM=dynamic PHP_FPM_MAX_CHILDREN=20
  run bin/entrypoint.sh php-fpm
  [ "$status" -eq 0 ]
  run cat "$LARAOCI_FPM_CONF_D/zz-laraoci.conf"
  [[ "$output" == *"[www]"* ]]
  [[ "$output" == *"pm.max_children = 20"* ]]
}

@test "entrypoint: no fpm template means no pool file (cli, builder)" {
  export LARAOCI_FPM_CONF_D="$TMP/php-fpm.d"
  mkdir -p "$LARAOCI_FPM_CONF_D"
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  [ ! -e "$LARAOCI_FPM_CONF_D/zz-laraoci.conf" ]
}

@test "entrypoint: the default pool directory is upstream's php-fpm.d" {
  # Every other pool test overrides LARAOCI_FPM_CONF_D, so the DEFAULT is the one
  # value in this file no behavioural test can reach - and getting it wrong is
  # silent: render() treats a missing directory as "not writable", logs a warning
  # and exits 0, so the container starts happily with no pool overlay at all.
  # `php.fpm.d` for `php-fpm.d` shipped exactly that until the build-time render
  # in images/fpm/Dockerfile caught it. Pinned statically because the real path
  # is root-owned and outside a test's reach.
  run grep -c 'LARAOCI_FPM_CONF_D:-/usr/local/etc/php-fpm.d' bin/entrypoint.sh
  [ "$output" -eq 1 ]
}

@test "entrypoint: an unset PHP_FPM_* variable is fatal, not a blank directive" {
  export LARAOCI_FPM_CONF_D="$TMP/php-fpm.d"
  mkdir -p "$LARAOCI_FPM_CONF_D"
  printf '[www]\npm = ${PHP_FPM_PM}\n' >"$TMP/templates/zz-laraoci-fpm.conf.template"
  unset PHP_FPM_PM
  run bin/entrypoint.sh php-fpm
  [ "$status" -ne 0 ]
  [[ "$output" == *"PHP_FPM_PM is unset"* ]]
}

