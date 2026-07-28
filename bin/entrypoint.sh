#!/bin/sh
# LaraOCI entrypoint - renders the PHP configuration from templates, then hands
# off to upstream's entrypoint (spec §6.4, LOCI-017/LOCI-018).
#
# Runs as ${USER_NAME}. The files it writes are pre-created at build time with
# that ownership; the surrounding conf.d directory stays root-owned.
set -eu

TEMPLATE_DIR="${LARAOCI_TEMPLATE_DIR:-/usr/local/share/laraoci/templates}"
CONF_D="${PHP_INI_DIR:-/usr/local/etc/php}/conf.d"

log() { echo "laraoci: $*" >&2; }

die() {
  log "$*"
  exit 1
}

# Render one template. envsubst is NEVER called bare: bare envsubst substitutes
# every $VAR in its input, which would blank FPM's built-in $pool and any value
# containing a literal '$'. The allowlist is derived from the ${VAR} references
# in the template itself, so there is one source of truth (§6.4) and bare $pool
# is out of scope by construction.
render() {
  template="$1"
  target="$2"

  [ -f "$template" ] || die "template $template not found"

  allowlist="$(grep -o "\${[A-Za-z_][A-Za-z0-9_]*}" "$template" | sort -u | tr '\n' ' ' || true)"

  # A variable that is unset or empty would render as a blank directive, which
  # PHP accepts and silently misconfigures. Fail instead.
  for ref in $allowlist; do
    name="${ref#\$\{}"
    name="${name%\}}"
    if ! value="$(printenv "$name")"; then
      die "$name is unset but $(basename "$template") requires it"
    fi
    if [ -z "$value" ]; then
      die "$name is empty but $(basename "$template") requires a value"
    fi
    # A newline in a value appends arbitrary directives to the rendered ini -
    # PHP_MEMORY_LIMIT='256M<newline>auto_prepend_file = /evil.php' is a
    # config-injection primitive for anyone who can set only that one variable.
    #
    # grep CANNOT be used here: it splits its input on newlines, so a newline is
    # a separator it never sees as content and '[[:cntrl:]]' matches nothing.
    # Counting bytes that survive `tr -d '[:print:]'` does work. Verified under
    # dash, which is /bin/sh in the image.
    if [ "$(printf '%s' "$value" | LC_ALL=C tr -d '[:print:]' | wc -c)" -ne 0 ]; then
      die "$name contains a non-printable character; refusing to render it into $(basename "$template")"
    fi
  done

  if ! tmp="$(mktemp 2>/dev/null)"; then
    log "warning: cannot create a temporary file; keeping the build-time $target"
    return 0
  fi
  # Every failure below leaves through die(); without this trap an envsubst
  # failure would exit on `set -e` and leave the temp file behind.
  trap 'rm -f "$tmp"' EXIT

  envsubst "$allowlist" <"$template" >"$tmp"

  if grep -q "\${" "$tmp"; then
    die "unsubstituted placeholders remain after rendering $template"
  fi

  if ! cat "$tmp" >"$target" 2>/dev/null; then
    log "warning: $target is not writable; keeping the build-time configuration"
  fi

  rm -f "$tmp"
  trap - EXIT
}

render "$TEMPLATE_DIR/zz-laraoci.ini.template" "$CONF_D/zz-laraoci.ini"

# Preload (§7.7, D14, 🧭 4). opcache in a short-lived CLI process is per-process:
# the shared segment is created at startup and destroyed at exit, so a preload
# there compiles the whole tree and throws it away on every `php artisan` call.
# The directive is therefore emitted only for php-fpm, or when a long-lived CLI
# worker opts in with LARAOCI_PRELOAD_FORCE=1 (that is how queue enables it in
# M3). The file is truncated when preload is off, so a restart without the
# variable does not leave a stale directive behind.
case "${1:-}" in
  -*) launched=php-fpm ;;
  *) launched="$(basename "${1:-}")" ;;
esac

preload_ini="$CONF_D/zz-laraoci-preload.ini"

if [ -n "${PHP_OPCACHE_PRELOAD:-}" ] &&
  { [ "$launched" = "php-fpm" ] || [ "${LARAOCI_PRELOAD_FORCE:-0}" = "1" ]; }; then
  if printf 'opcache.preload = %s\n' "$PHP_OPCACHE_PRELOAD" >"$preload_ini" 2>/dev/null; then
    log "preload enabled: $PHP_OPCACHE_PRELOAD"
  else
    log "warning: cannot write $preload_ini; preload not enabled"
  fi
else
  if [ -n "${PHP_OPCACHE_PRELOAD:-}" ]; then
    log "PHP_OPCACHE_PRELOAD is set but '$launched' is not an FPM process; ignoring (set LARAOCI_PRELOAD_FORCE=1 to override)"
  fi
  : >"$preload_ini" 2>/dev/null || true
fi

# 🧭 2: chain rather than replace. Upstream prepends the default binary when the
# first argument starts with '-', so `docker run image -v` keeps working. exec
# leaves no wrapper in the process tree.
exec docker-php-entrypoint "$@"
