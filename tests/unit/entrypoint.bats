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
