<?php

use Illuminate\Support\Facades\Schedule;

/*
| Built in M2, consumed by M3 (LOCI-037). The assertion there runs the scheduler
| for 70 seconds and counts the lines: a per-minute task must fire EXACTLY once
| in that window. One line proves the scheduler runs; more than one proves it is
| double-firing, which is what a misconfigured `schedule:work` alongside a cron
| entry looks like.
|
| One ISO-8601 timestamp per line, appended, so the count is the whole test and
| the timestamps make an unexpected count diagnosable.
*/
Schedule::call(function () {
    file_put_contents(
        storage_path('logs/schedule.log'),
        now()->toIso8601String()."\n",
        FILE_APPEND | LOCK_EX
    );
})->everyMinute();
