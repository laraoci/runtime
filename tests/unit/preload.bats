# config/php/preload.php, exercised on the HOST php rather than inside an image.
#
# THAT WORKS BECAUSE THE FAILURES BEING ASSERTED ARE STRUCTURAL - which
# directories the iterator can open - and none of them needs opcache. With
# opcache absent, opcache_compile_file() is simply an undefined function, the
# try/catch counts it as skipped, and the WALK is unchanged. So these assertions
# hold whether or not the host loads opcache, and none of them asserts a compiled
# count for that reason.
#
# tests/smoke/preload.bats is what asserts the opcache half - the directive, the
# statistics, the warning ceiling - in the image, where it means something.

setup() {
  command -v php >/dev/null || skip "php is not installed on the host"
  [ "$(id -u)" -ne 0 ] || skip "running as root ignores directory permissions"

  TMP="$(mktemp -d)"
  mkdir -p "$TMP/lib/sub"
  printf '<?php\nclass Fine {}\n' >"$TMP/lib/fine.php"
  printf '<?php\nclass Hidden {}\n' >"$TMP/lib/sub/hidden.php"
}

teardown() {
  # Restore traversal before removing: a chmod 000 directory is one rm -rf cannot
  # empty, and the failure would surface as an unrelated teardown error.
  chmod -R u+rwX "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}

@test "preload: a healthy tree logs the line everything else matches on" {
  LARAOCI_PRELOAD_ROOT="$TMP" LARAOCI_PRELOAD_PATHS=lib \
    run php config/php/preload.php
  [ "$status" -eq 0 ]
  [[ "$output" == *"laraoci: preloaded "* ]]
  [[ "$output" == *", skipped "* ]]
}

@test "preload: an unreadable SUBdirectory is skipped, not fatal (finding 2)" {
  # The iterator throws from next()/rewind(), which is OUTSIDE the try/catch that
  # wraps the compile - so this aborted PHP startup: exit 255 on a CLI worker, and
  # an FPM master that refuses to reach "ready to handle connections" (D32). A
  # bind-mounted vendor/ tree carries the host's modes, so any subtree the laravel
  # user cannot traverse reaches it - which is the same class of deployment
  # §7.7's empty-root no-op exists to protect.
  chmod 000 "$TMP/lib/sub"
  LARAOCI_PRELOAD_ROOT="$TMP" LARAOCI_PRELOAD_PATHS=lib \
    run php config/php/preload.php
  [ "$status" -eq 0 ]
  [[ "$output" != *"UnexpectedValueException"* ]]
  [[ "$output" != *"Fatal error"* ]]
  # THE WALK CONTINUES rather than being abandoned: the readable sibling is still
  # reached, which is what distinguishes CATCH_GET_CHILD from bailing out of the
  # whole path on the first unreadable subtree.
  [[ "$output" == *"laraoci: preloaded "* ]]
}

@test "preload: an unreadable ROOT path is skipped, not fatal (finding 2)" {
  # A different throw site: the RecursiveDirectoryIterator CONSTRUCTOR, which
  # fires before any iteration and which CATCH_GET_CHILD cannot see. is_dir()
  # returns true for a directory that cannot be opened, so the existing guard
  # does not help either.
  chmod 000 "$TMP/lib"
  LARAOCI_PRELOAD_ROOT="$TMP" LARAOCI_PRELOAD_PATHS=lib \
    run php config/php/preload.php
  [ "$status" -eq 0 ]
  [[ "$output" != *"UnexpectedValueException"* ]]
  [[ "$output" == *"laraoci: preloaded 0 files, skipped 0"* ]]
}

@test "preload: a missing path is still a silent no-op (§7.7 regression guard)" {
  # The safety property the whole design rests on, asserted here as well because
  # the change above adds a `continue` on a second path and must not disturb this
  # one.
  LARAOCI_PRELOAD_ROOT="$TMP" LARAOCI_PRELOAD_PATHS=nope \
    run php config/php/preload.php
  [ "$status" -eq 0 ]
  [[ "$output" == *"laraoci: preloaded 0 files, skipped 0"* ]]
}

@test "preload: a syntactically broken file is counted, not fatal" {
  # Already asserted in the image by tests/smoke/preload.bats case C. Repeated
  # here because it costs nothing and because it is the property the outer
  # try/catch below could plausibly break by swallowing the whole path.
  printf '<?php\nclass Broken {\n' >"$TMP/lib/broken.php"
  LARAOCI_PRELOAD_ROOT="$TMP" LARAOCI_PRELOAD_PATHS=lib \
    run php config/php/preload.php
  [ "$status" -eq 0 ]
  [[ "$output" == *"laraoci: preloaded "* ]]
}
