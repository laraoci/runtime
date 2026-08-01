# scheduler: one replica fires a per-minute task exactly once (LOCI-037, §7.6, D10).
#
# WHAT THIS CAN AND CANNOT PROVE. `scheduler`'s real failure mode is operational
# and un-assertable from inside a single container: two replicas double-fire every
# task, and no HEALTHCHECK or image-level guard can prevent that, because an image
# cannot know how many copies of itself are running. That constraint is DOCUMENTED
# (LOCI-039), not tested. What IS testable is the happy path the documentation
# depends on - ONE scheduler fires a per-minute task ONCE in a window - and that is
# this suite. Do not try to grow it into a double-fire test; it would need a second
# replica, and all it could then assert is that two schedulers fire twice, which is
# the documented behaviour rather than a defect.
#
# D31 - HOW THE TIMING IS MADE DETERMINISTIC. schedule:work fires on minute
# BOUNDARIES, so the obvious "start it and wait 70 s" is both slow and wrong: a
# window opening at :59 spans two boundaries and legitimately sees two fires, which
# would read as a double-fire defect. Rather than shortening the task's cadence
# (counting N fires in a short window is MORE race-prone, not less) or driving
# schedule:run in a loop (which would test a loop we wrote instead of the shipped
# CMD), the WINDOW is anchored to the clock:
#
#   1. start the container            4. sleep 60 s
#   2. sleep to the next boundary +5s 5. assert exactly one line
#   3. truncate schedule.log
#
# [b+5, b+65] contains exactly one boundary - b+60 - with 5 s of margin before it
# and 55 s after. Measured against this image on 2026-07-31, fires land on the
# boundary to the second (14:08:00, 14:09:00), so both margins are enormous
# relative to the jitter.
#
# THE COST IS ~2 MINUTES PER PHP VERSION and that is inherent: a per-minute task
# cannot be observed in less than a minute without changing what is being observed.
#
# Driven by tests/smoke/run.sh, which owns the stack and the teardown.

load helpers

setup_file() {
  require_smoke_env || return 1
  # migrate rather than merely install: Laravel's default cache store is the
  # database, and the fixture ships that migration precisely because of it. The
  # scheduled closure touches no table itself, but the framework booting around it
  # may, and a missing cache table would surface here as a mysterious zero-fire.
  ensure_app_migrated || return 1

  capture sched_up compose up --detach scheduler

  # Let schedule:work boot before the window is anchored. It is a couple of
  # seconds; the margin below absorbs far more than that.
  sleep 5

  # Anchor to the host clock. %-S strips the leading zero, which is load-bearing:
  # `08` and `09` are invalid octal and the arithmetic below would fail on them
  # for exactly two seconds in every minute.
  local secs
  secs="$(date -u +%-S)"
  sleep $(( (60 - secs) % 60 + 5 ))

  capture window_reset compose exec -T scheduler sh -c ': > storage/logs/schedule.log'
  sleep 60
  capture window_log compose exec -T scheduler cat storage/logs/schedule.log

  # Only ever read on a failure path, but captured inside the window's lifetime
  # so it describes the run that was measured.
  capture sched_logs compose logs --no-color scheduler
  capture sched_ps compose ps --format '{{.Name}}' scheduler
}

teardown_file() {
  # Leaving it up would have a live scheduler firing into the shared volume for
  # the remainder of the run, which every later suite shares.
  compose rm --stop --force scheduler >/dev/null 2>&1 || true
}

@test "scheduler: the container starts and stays up" {
  assert_step_ok sched_up
  # window_reset ran INSIDE the container 65 s after it started, so its success is
  # also the evidence that schedule:work did not boot, throw and exit - which
  # would otherwise show up only as a confusing zero-fire count below.
  assert_step_ok window_reset
}

@test "scheduler: exactly one replica is running" {
  # The premise of every assertion in this file. `single fire` is only meaningful
  # for a single replica, and this is what stops a future `deploy.replicas: 2` in
  # compose.yml from turning the count assertion below into a mystery.
  assert_step_ok sched_ps
  local n
  n="$(grep -c . <<<"$(step_output sched_ps)")"
  if [ "$n" != "1" ]; then
    echo "expected exactly 1 scheduler container, found $n:" >&2
    step_output sched_ps >&2
  fi
  [ "$n" = "1" ]
}

@test "scheduler: a per-minute task fires exactly once in a one-minute window" {
  assert_step_ok window_log

  local log count
  log="$(step_output window_log)"
  count="$(grep -c . <<<"$log" || true)"

  if [ "$count" != "1" ]; then
    echo "expected exactly 1 fire in the aligned window, got $count:" >&2
    echo "$log" >&2
    echo "scheduler container log:" >&2
    step_output sched_logs >&2
  fi
  # 0 means the scheduler is not running the task at all - a dead container, a
  # boot failure, or a task that threw. More than 1 means it double-fired, which
  # is what a second replica, or schedule:work running alongside a cron entry,
  # looks like from the application's point of view.
  [ "$count" = "1" ]
}

@test "scheduler: the fire landed on a minute boundary" {
  # Guards the count above. A single line that arrived at :37 would mean the task
  # ran for some reason other than the boundary tick - and the count would then be
  # right for the wrong reason. Measured fires land at exactly :00; the tolerance
  # is generous so that a loaded runner does not go red for being slow.
  local ts secs
  ts="$(grep -m1 . <<<"$(step_output window_log)")"
  [ -n "$ts" ]
  secs="$(date -d "$ts" +%-S)"
  if ((secs > 9)); then
    echo "fire at $ts is ${secs}s past the minute - not a boundary tick" >&2
    step_output sched_logs >&2
  fi
  ((secs <= 9))
}
