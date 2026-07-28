<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

/**
 * A job that takes a known, controllable amount of wall-clock time.
 *
 * Built in M2, consumed by M3 (LOCI-036). The two markers are the whole point:
 * a worker that is killed mid-job writes `start` and never writes `end`, so the
 * pair distinguishes a GRACEFUL shutdown from a truncated one. Asserting only
 * that the job ran would pass either way.
 *
 * The sleep is done in one-second increments rather than one long sleep because
 * a signal interrupts nanosleep (EINTR) and PHP returns early from it - a single
 * sleep($seconds) would come back almost immediately when SIGTERM arrives and
 * report a completion that never really took the time it claims. The loop
 * re-enters the sleep, so the elapsed time is real.
 */
class SleepJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $seconds = 3) {}

    public function handle(): void
    {
        $this->log('start');

        for ($i = 0; $i < $this->seconds; $i++) {
            sleep(1);
        }

        $this->log('end');
    }

    private function log(string $marker): void
    {
        file_put_contents(
            storage_path('logs/job.log'),
            $marker.' '.now()->toIso8601String()."\n",
            FILE_APPEND | LOCK_EX
        );
    }
}
