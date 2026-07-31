# queue: graceful shutdown under SIGTERM (LOCI-036, spec §7.5, §6.2).
#
# THE LOAD-BEARING WORKER TEST. `queue` exists to be more than "cli with a CMD"
# for exactly one reason: `docker stop` must let an in-flight job finish. That
# drain depends on four things lining up, and only the last is in the queue
# Dockerfile - pcntl+posix compiled in (runtime), STOPSIGNAL SIGTERM (runtime,
# and correct here where fpm had to override it), tini forwarding the signal as
# PID 1 (D9), and queue:work invoked, so it actually traps. This suite is what
# proves all four are wired.
#
# WHY THE MARKER PAIR AND NOT "THE JOB RAN". SleepJob writes `start`, sleeps for
# a real (EINTR-safe) number of seconds, then writes `end`. A drained worker
# writes both; a killed worker writes only `start`. Asserting completion alone
# passes either way - which is what the SleepJob docblock warns about, and the
# reason LOCI-036 is named separately from the rest of the smoke suite.
#
# WHY A NEGATIVE CONTROL. A test that only ever sees a passing drain cannot tell
# a working trap from a job short enough to finish before anything killed it. The
# second case runs a 20 s job against a 2 s grace period - the exact failure the
# LOCI-039 documentation warns about - and asserts the truncation is visible.
#
# Driven by tests/smoke/run.sh, which owns the stack and the teardown.

load helpers

setup_file() {
  require_smoke_env || return 1
  ensure_app_migrated || return 1

  # --- Case 1: a grace period LONGER than the job. Expect a drain. -----------
  # 8 s of work against 30 s of grace. The margin is what makes this
  # deterministic; the assertion below still checks the elapsed time rather than
  # trusting it.
  capture drain_reset compose run --rm cli sh -c ': > storage/logs/job.log'
  capture drain_enqueue compose run --rm cli php artisan smoke:enqueue 8
  capture drain_up compose up --detach queue

  # Wait for the worker to have STARTED the job before stopping it. A fixed
  # sleep would either stop before the job began - proving nothing about a drain
  # - or after it finished, which passes with no trap at all. `exec` into the
  # live container rather than `run --rm cli`, so polling costs milliseconds.
  local i
  for i in $(seq 1 30); do
    if compose exec -T queue grep -q '^start ' storage/logs/job.log 2>/dev/null; then
      break
    fi
    sleep 1
  done

  # THE STATE OF job.log AT THE MOMENT OF THE STOP, kept as content rather than
  # as a grep's exit status. The whole suite rests on the job being IN FLIGHT
  # when SIGTERM arrives: if it had already finished, `end` would be present
  # before the stop and the drain assertion below would pass without a trap
  # existing at all. Recording the content is what makes that falsifiable - see
  # the case that asserts `end` is absent here.
  capture drain_midflight compose exec -T queue cat storage/logs/job.log

  capture drain_stop compose stop --timeout 30 queue
  capture drain_log compose run --rm cli cat storage/logs/job.log
  compose rm --stop --force queue >/dev/null 2>&1 || true

  # --- Case 2: a grace period SHORTER than the job. Expect a truncation. -----
  # 20 s of work against 2 s of grace: docker sends SIGTERM, waits 2 s, then
  # SIGKILLs. The 18 s margin is what keeps this from being a race.
  capture kill_reset compose run --rm cli sh -c ': > storage/logs/job.log'
  capture kill_enqueue compose run --rm cli php artisan smoke:enqueue 20
  capture kill_up compose up --detach queue

  for i in $(seq 1 30); do
    if compose exec -T queue grep -q '^start ' storage/logs/job.log 2>/dev/null; then
      break
    fi
    sleep 1
  done

  capture kill_stop compose stop --timeout 2 queue
  capture kill_log compose run --rm cli cat storage/logs/job.log

  # Docker's own record of HOW the worker died, read before `rm` discards the
  # container. 137 is 128+9 - SIGKILL - which is the grace period expiring. It
  # separates "docker killed it mid-job" from "the worker exited by itself
  # without finishing", two states the marker file cannot tell apart.
  local cid
  cid="$(compose ps -aq queue 2>/dev/null | head -1)"
  if [ -n "$cid" ]; then
    docker inspect "$cid" --format '{{.State.ExitCode}}' \
      >"$BATS_FILE_TMPDIR/kill.exitcode" 2>/dev/null || echo unknown >"$BATS_FILE_TMPDIR/kill.exitcode"
  else
    echo unknown >"$BATS_FILE_TMPDIR/kill.exitcode"
  fi

  compose rm --stop --force queue >/dev/null 2>&1 || true
}

teardown_file() {
  # The worker holds the shared sqlite file and would keep draining the retry of
  # the job case 2 truncated. Every later suite in the glob runs against this
  # same stack, so leaving it up is not a tidiness issue.
  compose rm --stop --force queue >/dev/null 2>&1 || true
}

@test "queue: the worker picks up a queued job" {
  assert_step_ok drain_enqueue
  assert_step_ok drain_midflight
  [[ "$(step_output drain_midflight)" == *"start "* ]]
}

@test "queue: the job is still in flight when the stop is issued" {
  # THE GUARD ON THE NEXT CASE. "Both markers after a stop" only proves a drain
  # if the job had not already finished before the stop was sent. On a slow
  # runner the poll loop could return late, the 8 s job could complete, and the
  # drain assertion would go green against a worker with no signal handling
  # whatsoever. Asserting `end` is ABSENT at this instant is what excludes that,
  # and it is the difference between a test and a coincidence.
  local mid
  mid="$(step_output drain_midflight)"
  if [[ "$mid" == *"end "* ]]; then
    echo "the job had already finished before the stop was issued:" >&2
    echo "$mid" >&2
    echo "the drain assertion that follows would pass without proving anything." >&2
    echo "raise SleepJob's duration or shorten the poll interval." >&2
  fi
  [[ "$mid" == *"start "* ]]
  [[ "$mid" != *"end "* ]]
}

@test "queue: docker stop drains the in-flight job (start AND end)" {
  assert_step_ok drain_stop

  local log
  log="$(step_output drain_log)"
  if [[ "$log" != *"start "* || "$log" != *"end "* ]]; then
    echo "job.log after a 30s-grace stop of an 8s job:" >&2
    echo "$log" >&2
    echo "compose logs for the worker:" >&2
    compose logs queue >&2 2>&1 || true
  fi
  [[ "$log" == *"start "* ]]
  [[ "$log" == *"end "* ]]
}

@test "queue: the drained job really took its full time (the EINTR guard)" {
  # `end` present is not by itself proof the work happened: a signal interrupts
  # nanosleep and PHP returns early, so a single sleep($n) would report a
  # completion that never took the time it claims. SleepJob loops one-second
  # sleeps precisely to defeat that, and this asserts the outcome - the elapsed
  # wall time between the two markers is at least the job's duration.
  local log start end
  log="$(step_output drain_log)"
  start="$(sed -n 's/^start //p' <<<"$log" | head -1)"
  end="$(sed -n 's/^end //p' <<<"$log" | head -1)"
  [ -n "$start" ]
  [ -n "$end" ]

  local elapsed
  elapsed=$(( $(date -d "$end" +%s) - $(date -d "$start" +%s) ))
  if ((elapsed < 7)); then
    echo "start=$start end=$end elapsed=${elapsed}s, expected >= 7 for an 8s job" >&2
  fi
  ((elapsed >= 7))
}

@test "queue: a grace period shorter than the job truncates it (negative control)" {
  local log
  log="$(step_output kill_log)"
  if [[ "$log" != *"start "* || "$log" == *"end "* ]]; then
    echo "job.log after a 2s-grace stop of a 20s job:" >&2
    echo "$log" >&2
  fi
  # `start` proves the job was really running when the grace period expired -
  # without it, the absence of `end` would be satisfied by a worker that never
  # picked anything up, and this control would pass while proving nothing.
  [[ "$log" == *"start "* ]]
  [[ "$log" != *"end "* ]]
}

@test "queue: the truncated worker was killed by docker, not exited cleanly" {
  # The marker file shows work that did not finish; it cannot show WHY. 137 is
  # 128+9, SIGKILL - Docker's grace period expiring on a worker still holding a
  # job. A clean exit code here would mean queue:work gave up on its own, which
  # is a different defect wearing the same evidence.
  local code
  code="$(cat "$BATS_FILE_TMPDIR/kill.exitcode")"
  if [ "$code" != "137" ]; then
    echo "expected exit 137 (SIGKILL after the 2s grace), got '$code'" >&2
  fi
  [ "$code" = "137" ]
}
