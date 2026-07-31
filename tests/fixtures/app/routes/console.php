<?php

use App\Jobs\SleepJob;
use Illuminate\Support\Facades\Artisan;
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

/*
| LOCI-036's enqueue side. A closure command rather than `tinker --execute`,
| because laravel/tinker is a dev dependency the fixture deliberately does not
| carry, and rather than a `php -r` bootstrap in the .bats file, because the
| queue payload has to be built by the same application the worker will boot.
|
| $seconds is cast rather than type-hinted: console arguments arrive as strings
| and this file has no declare(strict_types=1) to lean on, so an `int` hint would
| work by coercion today and break the day one is added.
*/
Artisan::command('smoke:enqueue {seconds=8}', function ($seconds) {
    SleepJob::dispatch((int) $seconds);

    $this->info('queued SleepJob('.(int) $seconds.')');
})->purpose('Queue one SleepJob for the LOCI-036 graceful-shutdown assertion');
