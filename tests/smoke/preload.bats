# preload: enabled on a real tree, safe on an empty one (LOCI-038, §7.7, D14/D22).
#
# THREE CASES, because the preload script's failure surface is wider than "does it
# run", and every one of §7.7's constraints is a way it can silently do the wrong
# thing:
#
#   A  Populated vendor/. The script must compile a non-trivial number of files
#      and opcache_get_status() must agree with the line it logged. This also
#      proves D29 end to end: `launched` is `php`, not `php-fpm`, so the ONLY
#      reason the D22 SAPI gate opens is the LARAOCI_PRELOAD_FORCE=1 baked into
#      the queue image.
#   B  Empty root. The script must no-op, log zero, and the container must come up
#      CLEAN. The alternative - a fatal that takes the worker down on start -
#      would be catastrophic on exactly the bind-mount deployments most likely to
#      hit it, and it is silent until it happens. This is the safety property the
#      whole design rests on.
#   C  A syntactically broken file inside the preload path. It must be counted as
#      skipped and must NOT abort the run. The set_error_handler that keeps the
#      startup log readable also hides real errors, so the behaviour on a genuine
#      failure is asserted rather than assumed - and an uncaught error here would
#      not merely log badly, it would abort PHP startup (D32).
#
# Cases B and C run `docker run` DIRECTLY rather than through a compose service,
# and that is the point of them: "this image with no application volume at all" is
# the deployment shape being tested, and a compose service exists to mount one.
# helpers' image_ref() is what makes that expressible.
#
# THE cli-SIDE NEGATIVE IS DELIBERATELY NOT REPEATED HERE. That
# PHP_OPCACHE_PRELOAD on `cli` enables nothing is asserted statically by
# tests/structure/cli.yaml, and D24 says static if it can be.

load helpers

PRELOAD=/usr/local/share/laraoci/preload.php

setup_file() {
  require_smoke_env || return 1
  ensure_app_installed || return 1

  # --- Case A: populated vendor/, through the real entrypoint on `queue`. ------
  # No LARAOCI_PRELOAD_* overrides: this must exercise the DEFAULTS the image
  # ships, because those defaults are what an operator gets.
  capture on compose run --rm \
    -e PHP_OPCACHE_PRELOAD="$PRELOAD" \
    -e PHP_OPCACHE_MEMORY_CONSUMPTION=320 \
    queue php -r '
      $s = opcache_get_status()["preload_statistics"] ?? [];
      printf("STATS scripts=%d classes=%d functions=%d memory=%d max_files=%d%s",
        count($s["scripts"] ?? []), count($s["classes"] ?? []),
        count($s["functions"] ?? []), (int) ($s["memory_consumption"] ?? 0),
        (int) ini_get("opcache.max_accelerated_files"), PHP_EOL);'

  # --- Case B: no application volume at all. ----------------------------------
  capture empty docker run --rm \
    -e PHP_OPCACHE_PRELOAD="$PRELOAD" \
    "$(image_ref queue)" php -r 'echo "STARTED-CLEAN", PHP_EOL;'

  # --- Case C: a broken file inside the preload path. -------------------------
  # The `sh` wrapper writes the files and is NOT itself preloaded - the directive
  # the entrypoint wrote applies to the php process started after it - so the
  # broken file is guaranteed to exist before the run that must survive it.
  capture broken docker run --rm \
    -e PHP_OPCACHE_PRELOAD="$PRELOAD" \
    -e LARAOCI_PRELOAD_ROOT=/tmp/preload-root \
    -e LARAOCI_PRELOAD_PATHS=lib \
    "$(image_ref queue)" sh -c '
      mkdir -p /tmp/preload-root/lib
      printf "<?php\nclass Fine {}\n" > /tmp/preload-root/lib/fine.php
      printf "<?php\nclass Broken {\n" > /tmp/preload-root/lib/broken.php
      php -r "echo \"SURVIVED\n\";"'

  # --- Case D: an UNREADABLE DIRECTORY inside the preload path. ----------------
  # Case C's sibling, and the more dangerous half. A broken FILE throws inside
  # opcache_compile_file(), where the try/catch is; an unreadable DIRECTORY throws
  # from the ITERATOR, which was outside it - so this aborted PHP startup
  # outright (D32) rather than merely logging badly. A bind-mounted vendor/ tree
  # carries the host's modes, so this is reachable without anyone doing anything
  # unusual.
  #
  # The readable sibling is asserted as well as the survival: skipping the subtree
  # it cannot open must not abandon the whole walk.
  capture unreadable docker run --rm \
    -e PHP_OPCACHE_PRELOAD="$PRELOAD" \
    -e LARAOCI_PRELOAD_ROOT=/tmp/preload-root \
    -e LARAOCI_PRELOAD_PATHS=lib \
    "$(image_ref queue)" sh -c '
      mkdir -p /tmp/preload-root/lib/sub
      printf "<?php\nclass Fine {}\n" > /tmp/preload-root/lib/fine.php
      printf "<?php\nclass Hidden {}\n" > /tmp/preload-root/lib/sub/hidden.php
      chmod 000 /tmp/preload-root/lib/sub
      php -r "echo \"SURVIVED\n\";"'
}

@test "preload: the entrypoint enables it on a long-lived worker (D29, D22)" {
  assert_step_ok on
  # The queue image's only preload-specific content is LARAOCI_PRELOAD_FORCE=1.
  # This line cannot appear without it, because `launched` here is `php`: on
  # `cli`, the identical invocation writes an empty directive file (cli.yaml).
  [[ "$(step_output on)" == *"laraoci: preload enabled: $PRELOAD"* ]]
}

@test "preload: a populated vendor tree compiles a non-trivial number of files" {
  local out compiled
  out="$(step_output on)"
  compiled="$(sed -n 's/.*laraoci: preloaded \([0-9]*\) files.*/\1/p' <<<"$out" | head -1)"

  if [ -z "$compiled" ] || ((compiled < 100)); then
    echo "startup line reported '${compiled:-<none>}' compiled files:" >&2
    echo "$out" >&2
  fi
  # A FLOOR, not an exact number. §7.7 is explicit that tuning is measured with
  # opcache_get_status() rather than by asserting a count, and the Illuminate tree
  # moves with every framework release - it is ~1325 today. But zero, or a
  # handful, would mean the default path set missed the tree entirely, which is
  # precisely the silent failure this case exists to catch.
  [ -n "$compiled" ]
  ((compiled >= 100))
}

@test "preload: opcache_get_status confirms what the startup line claims" {
  # The startup line counts opcache_compile_file() successes; preload_statistics
  # is opcache's own record. They are NOT required to be equal - a class that
  # cannot be linked is dropped - so the assertion is that both are non-zero and
  # describe the same event, not that they match.
  local out scripts classes mem
  out="$(step_output on)"
  scripts="$(sed -n 's/.*scripts=\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
  classes="$(sed -n 's/.*classes=\([0-9]*\).*/\1/p' <<<"$out" | head -1)"
  mem="$(sed -n 's/.*memory=\([0-9]*\).*/\1/p' <<<"$out" | head -1)"

  if [ -z "$scripts" ] || ((scripts == 0)); then
    echo "preload_statistics reported no scripts:" >&2
    echo "$out" >&2
  fi
  ((scripts > 0))
  ((classes > 0))
  ((mem > 0))
}

@test "preload: max_accelerated_files exceeds the preloaded count (§7.7)" {
  # The misconfiguration that LOOKS like success: past the ceiling, compilation
  # stops part way and the startup line reports a number LOWER than reality. §6.5
  # sets 20000 against a tree of ~1325, so this asserts the RELATIONSHIP rather
  # than either number - a framework that grew tenfold would fail here instead of
  # silently truncating.
  local out compiled max
  out="$(step_output on)"
  compiled="$(sed -n 's/.*laraoci: preloaded \([0-9]*\) files.*/\1/p' <<<"$out" | head -1)"
  max="$(sed -n 's/.*max_files=\([0-9]*\).*/\1/p' <<<"$out" | head -1)"

  if ((compiled >= max)); then
    echo "preloaded $compiled files against max_accelerated_files=$max" >&2
  fi
  ((compiled < max))
}

@test "preload: the default ignore set keeps the startup log readable (D33)" {
  # The operator-facing half of D33. "Can't preload unlinked class" warnings are
  # emitted by opcache's LINK phase, after the script has returned, so no error
  # handler in the script can suppress them - the only lever is what gets
  # compiled. Before /Console/ joined the default ignore set this was 176 lines
  # (~48 KB) at every start, which reads as a broken image; it is ~45 now.
  #
  # A CEILING WITH HEADROOM, not the exact count: the residual warnings name
  # parents in Symfony/Psr/Monolog/Guzzle and will drift with the framework. 100
  # is comfortably above today's 45 and comfortably below the 176 this exists to
  # prevent regressing to.
  local warnings
  warnings="$(grep -ac "Can't preload unlinked" <<<"$(step_output on)" || true)"
  if ((warnings >= 100)); then
    echo "$warnings unlinked-class warnings at startup - D33's ignore set may have regressed" >&2
    echo "expected ~45; 176 is the value before /Console/ was ignored" >&2
  fi
  ((warnings < 100))
}

@test "preload: an empty root no-ops and the container starts clean" {
  assert_step_ok empty

  local out
  out="$(step_output empty)"
  if [[ "$out" != *"STARTED-CLEAN"* ]]; then
    echo "the container did not come up with preload named and no vendor tree:" >&2
    echo "$out" >&2
  fi
  # THE SAFETY PROPERTY. Silent, not fatal, by design (§7.7): the alternative
  # takes the worker down on start on exactly the bind-mount deployments most
  # likely to hit it.
  [[ "$out" == *"STARTED-CLEAN"* ]]
  [[ "$out" == *"laraoci: preloaded 0 files, skipped 0"* ]]
  [[ "$out" != *"Failed to preload"* ]]
  [[ "$out" != *"Fatal error"* ]]
}

@test "preload: a syntactically broken file is counted, not fatal" {
  assert_step_ok broken

  local out skipped
  out="$(step_output broken)"
  skipped="$(sed -n 's/.*skipped \([0-9]*\).*/\1/p' <<<"$out" | head -1)"

  if [[ "$out" != *"SURVIVED"* ]]; then
    echo "a broken file in the preload path aborted the run:" >&2
    echo "$out" >&2
  fi
  # Both halves matter and the first would HIDE the failure of the second: the
  # error handler keeps the log readable, the try/catch keeps a bad file from
  # taking the process with it. An uncaught error during preload aborts PHP
  # startup outright (D32), so "SURVIVED" is the load-bearing word here.
  [[ "$out" == *"SURVIVED"* ]]
  [[ "$out" != *"Fatal error"* ]]
  [ -n "$skipped" ]
  ((skipped >= 1))
}

@test "preload: an unreadable directory is skipped, not fatal (finding 2)" {
  assert_step_ok unreadable

  local out compiled
  out="$(step_output unreadable)"
  compiled="$(sed -n 's/.*laraoci: preloaded \([0-9]*\) files.*/\1/p' <<<"$out" | head -1)"

  if [[ "$out" != *"SURVIVED"* ]]; then
    echo "an unreadable directory in the preload path aborted the run:" >&2
    echo "$out" >&2
  fi
  # SURVIVED is the load-bearing word, exactly as in case C: an uncaught error
  # during preload aborts PHP startup (D32), and on fpm that is a master that
  # never serves a request.
  [[ "$out" == *"SURVIVED"* ]]
  [[ "$out" != *"Fatal error"* ]]
  [[ "$out" != *"UnexpectedValueException"* ]]
  # The readable sibling still compiled - the unreadable subtree was skipped, not
  # the whole path.
  [ "$compiled" = "1" ]
}
