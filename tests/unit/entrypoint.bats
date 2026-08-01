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
  # Restore write permission before removing: a test that makes conf.d itself
  # read-only (the read-only-rootfs case) leaves a directory rm -rf cannot
  # empty, and the failure would surface as an unrelated teardown error.
  chmod -R u+rwX "$TMP" 2>/dev/null || true
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

@test "entrypoint: no special builtin takes a bare redirection (dash exits on it)" {
  # `:` is a POSIX SPECIAL builtin, and a redirection error on a special builtin
  # exits a non-interactive shell outright - before `|| true` is ever evaluated,
  # and without `2>/dev/null` suppressing the shell's own message. So
  # `: >"$f" 2>/dev/null || true` is soft under bash and FATAL under dash, which
  # is /bin/sh in the image. Wrap it in a subshell, which contains the exit.
  #
  # Static, because the behavioural version below needs both dash and a non-root
  # uid; this one runs everywhere and is what fails if the bare form comes back.
  run grep -nE '^[[:space:]]*:[[:space:]]*>' bin/entrypoint.sh
  [ "$status" -ne 0 ]
}

@test "entrypoint: stderr is suppressed BEFORE the write it guards, not after" {
  # Redirections are applied left to right, so `cmd >"$target" 2>/dev/null`
  # suppresses the wrong stream: >"$target" fails first, while stderr is still
  # the terminal, and the shell prints its own "cannot create …: Permission
  # denied". What 2>/dev/null then covers is the stderr of a command that never
  # ran. `docker run --user 5000` showed that line above the deliberate error
  # message, which made a designed refusal read as a crash.
  #
  # Same family as the special-builtin guard above: a redirection failure the
  # suppression does not reach. Both are invisible under a writable target,
  # which is every environment except the one the message exists for.
  #
  # Matches a write redirection followed later on the line by 2>/dev/null. The
  # subshell form `(: >"$f") 2>/dev/null` is correctly ordered - the redirect on
  # the subshell is applied before anything inside it runs - and does not match,
  # because its > is inside the parens.
  run grep -nE '[^)] >"[^"]+" 2>/dev/null' bin/entrypoint.sh
  [ "$status" -ne 0 ]
}

@test "entrypoint: an unwritable conf.d does not kill the opt-out (dash, L5)" {
  # The behavioural half of the guard above, and the case the escape hatch
  # exists for: on a read-only rootfs conf.d ITSELF is unwritable, not just the
  # ini. render() then takes the documented soft path - but the preload clear
  # below it used to exit 2 under dash, so the container died anyway and
  # LARAOCI_ALLOW_UNWRITABLE_CONFIG=1 bought nothing.
  #
  # Runs dash explicitly rather than trusting /bin/sh: bash is /bin/sh on Fedora
  # and dash on the Ubuntu runners, so via the shebang alone this would be a
  # test that silently checks nothing on half the machines it runs on.
  local dash
  dash="$(command -v dash || true)"
  [ -n "$dash" ] || skip "dash is not installed"
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores file permissions"

  # BOTH, and for different reasons. 0444 on the ini is what makes render() take
  # the soft path - a read-only DIRECTORY alone would not, since rewriting an
  # existing writable file never needs write permission on its parent. 0555 on
  # conf.d is what makes the preload clear fail, because that file does not
  # exist yet and creating it does need the directory.
  echo 'memory_limit = 999M' >"$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  chmod 0444 "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  chmod 0555 "$PHP_INI_DIR/conf.d"
  export LARAOCI_ALLOW_UNWRITABLE_CONFIG=1
  run "$dash" bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff: php -v"* ]]
  [[ "$output" == *"IGNORED"* ]]
}

@test "entrypoint: an unwritable target is fatal, not a silent fallback" {
  # This used to warn and start anyway, so `docker run --user 5000 -e
  # PHP_MEMORY_LIMIT=1G` served traffic at the build-time 256M with one line on
  # stderr. The asymmetry against an unset variable - which has always been
  # fatal - is what made it indefensible: both cases end with the operator not
  # getting the configuration they asked for.
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores file permissions"
  echo 'memory_limit = 999M' >"$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  chmod 0444 "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not writable"* ]]
  [[ "$output" == *"LARAOCI_ALLOW_UNWRITABLE_CONFIG"* ]]
}

@test "entrypoint: LARAOCI_ALLOW_UNWRITABLE_CONFIG=1 restores the soft fallback" {
  # The escape hatch for a read-only rootfs, where the build-time configuration
  # IS the intended one. Opt-in, so the operator has stated that they know the
  # overrides will not apply.
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores file permissions"
  echo 'memory_limit = 999M' >"$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  chmod 0444 "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  export LARAOCI_ALLOW_UNWRITABLE_CONFIG=1
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"IGNORED"* ]]
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
  # value in this file no behavioural test can reach. Getting it wrong used to be
  # silent as well: render() treated a missing directory as "not writable", logged
  # a warning and exited 0, so the container started happily with no pool overlay
  # at all. `php.fpm.d` for `php-fpm.d` shipped exactly that until the build-time
  # render in images/fpm/Dockerfile caught it. It is a hard failure now rather
  # than a warning, but the static assertion stays: the real path is root-owned
  # and outside a test's reach, so nothing behavioural can reach the DEFAULT value.
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

@test "entrypoint: a newline in PHP_OPCACHE_PRELOAD is fatal (L3, same rule as the ini)" {
  # render() refuses a non-printable character because one newline turns a single
  # variable into "append any directive you like". The preload directive is
  # written by a bare printf that skipped that check, so PHP_OPCACHE_PRELOAD was
  # the one variable the guard did not cover - and zz-laraoci-preload.ini sorts
  # AFTER zz-laraoci.ini, so an injected directive wins over the baseline.
  export LARAOCI_DEFAULT_BINARY=php-fpm
  PHP_OPCACHE_PRELOAD="$(printf '/app/preload.php\nauto_prepend_file = /tmp/pwn.php')"
  export PHP_OPCACHE_PRELOAD
  run bin/entrypoint.sh php-fpm
  [ "$status" -ne 0 ]
  [[ "$output" == *"PHP_OPCACHE_PRELOAD contains a non-printable character"* ]]
}

@test "entrypoint: a rejected preload writes no directive at all" {
  # Not just "the process died" - the file must not carry the injected line, or a
  # restart without the variable would still boot with it.
  export LARAOCI_DEFAULT_BINARY=php-fpm
  PHP_OPCACHE_PRELOAD="$(printf '/app/preload.php\nauto_prepend_file = /tmp/pwn.php')"
  export PHP_OPCACHE_PRELOAD
  run bin/entrypoint.sh php-fpm
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci-preload.ini"
  [[ "$output" != *"auto_prepend_file"* ]]
}

@test "entrypoint: an unwritable TMPDIR is fatal, not a silent fallback (finding 4)" {
  # THE ASYMMETRY THIS CLOSES. The write path below is fatal by default because a
  # container that cannot render the ini starts on the BUILD-TIME configuration
  # and silently ignores everything the operator set. mktemp failing produces the
  # identical outcome - and it returned 0 BEFORE the opt-out was consulted, so the
  # escape hatch was not merely unnecessary there, it was unreachable.
  #
  # Measured on the built image: `--read-only` alone started happily on 256M with
  # PHP_MEMORY_LIMIT=1024M discarded, while `--read-only --tmpfs /tmp` refused
  # with exit 1. Adding a writable /tmp made the container STRICTER.
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores file permissions"
  echo 'memory_limit = 999M' >"$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  mkdir -p "$TMP/notmp"
  chmod 0555 "$TMP/notmp"
  TMPDIR="$TMP/notmp" PHP_MEMORY_LIMIT=1024M run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"no writable temporary directory"* ]]
  [[ "$output" == *"LARAOCI_ALLOW_UNWRITABLE_CONFIG"* ]]
  # The build-time file is left exactly as it was - refusing to start must not
  # half-write the configuration it refused to render.
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *"999M"* ]]
}

@test "entrypoint: LARAOCI_ALLOW_UNWRITABLE_CONFIG=1 covers an unwritable TMPDIR too" {
  # The read-only-rootfs case, where the build-time configuration IS the intended
  # one. One flag, both failure paths - which is the whole point of the change.
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores file permissions"
  echo 'memory_limit = 999M' >"$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  mkdir -p "$TMP/notmp"
  chmod 0555 "$TMP/notmp"
  export LARAOCI_ALLOW_UNWRITABLE_CONFIG=1
  TMPDIR="$TMP/notmp" run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"IGNORED"* ]]
  [[ "$output" == *"handoff: php -v"* ]]
}

@test "entrypoint: a template referencing PHP_* without braces is fatal (finding 9)" {
  # The allowlist is derived from ${VAR} references, so a bare $PHP_MEMORY_LIMIT
  # is excluded from it - envsubst leaves it alone - AND passes the post-render
  # check, which looks for '${'. The result is a literal '$PHP_MEMORY_LIMIT' in
  # php.ini, which PHP accepts as a string and silently misconfigures.
  #
  # Caught at the TEMPLATE, not in the rendered output: a bare $VAR SURVIVING is
  # required behaviour for FPM's built-in $pool (trap 2, asserted above), so the
  # rendered file cannot distinguish the two. Our own namespace can: a bare
  # reference to PHP_* or LARAOCI_* is only ever a mistake.
  cat >"$TMP/templates/zz-laraoci.ini.template" <<'TPL'
memory_limit = $PHP_MEMORY_LIMIT
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
TPL
  run bin/entrypoint.sh php -v
  [ "$status" -ne 0 ]
  [[ "$output" == *"PHP_MEMORY_LIMIT"* ]]
  [[ "$output" == *"braces"* ]]
}

@test "entrypoint: a bare \$VAR outside our namespace is still fine (trap 2)" {
  # The check must not become a ban on the '$' character. $pool is FPM's own and
  # must reach the pool file verbatim; an unrelated $VAR is none of our business.
  # Comment lines are exempt so prose may name a variable.
  cat >"$TMP/templates/zz-laraoci.ini.template" <<'TPL'
; documents ${PHP_MEMORY_LIMIT} and mentions $PHP_MAX_EXECUTION_TIME in prose
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
; pool = $pool
; untouched = $NOT_MINE
TPL
  run bin/entrypoint.sh php -v
  [ "$status" -eq 0 ]
  run cat "$PHP_INI_DIR/conf.d/zz-laraoci.ini"
  [[ "$output" == *'$pool'* ]]
  [[ "$output" == *'$NOT_MINE'* ]]
}
