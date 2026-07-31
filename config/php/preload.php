<?php

/*
 * LaraOCI preload script - spec §7.7, D14. Ships at
 * /usr/local/share/laraoci/preload.php on EVERY image (D30) and is INERT unless
 * PHP_OPCACHE_PRELOAD names it.
 *
 * Naming it is necessary but not sufficient: bin/entrypoint.sh writes the
 * opcache.preload directive only when the launched process is php-fpm, or when a
 * long-lived CLI worker opts in with LARAOCI_PRELOAD_FORCE=1 (D22). `queue` is
 * the one image that bakes that flag (D29).
 *
 * CONSTRAINTS, each of which is a way this file can silently do the wrong thing:
 *
 *   - An EMPTY root is a no-op, not a fatal. Both default paths are missing on a
 *     bind-mount deployment with no vendor tree yet, `is_dir` sends them to
 *     `continue`, and the run logs zero. A fatal here would take the worker down
 *     on start, on exactly the deployments most likely to hit it.
 *   - opcache.max_accelerated_files MUST exceed the compiled count. §6.5 sets
 *     20000; the fixture's Illuminate + composer tree measures 1534 files after
 *     the ignore filter (2026-07-31), so there is 13x headroom. Past the ceiling
 *     compilation stops part way and the line below reports a number LOWER than
 *     reality - a misconfiguration that reads as success.
 *   - opcache.preload_user is deliberately ABSENT. It is only required when the
 *     FPM master runs as root: measured 2026-07-31, the same image as root dies
 *     with `"opcache.preload" requires "opcache.preload_user" when running under
 *     uid 0`, and at uid 1000 it preloads and reaches "ready to handle
 *     connections". LaraOCI runs as `laravel` throughout, so do not add it.
 *   - vendor/symfony is deliberately OUT of the default path set (§7.7,
 *     reversing the v1 draft): Illuminate already drags in the Symfony
 *     components it uses, the rest inflates preload memory for no hit-rate gain,
 *     and it is the largest source of benign "unlinked class" skips - which
 *     makes the startup line misleading.
 *   - /Console/ is IN the default ignore set (D33), and it is the consequence of
 *     the line above rather than an independent choice. With vendor/symfony
 *     excluded, Illuminate\Console\Command cannot link its Symfony parent, and 78
 *     command subclasses fail behind it. Measured on the fixture's Laravel 13
 *     tree, 2026-07-31:
 *
 *       default            1534 compiled, 176 warnings, 21.9 MB
 *       + /Console/        1325 compiled,  45 warnings, 19.5 MB
 *
 *     Of the 224 named classes that drop out, 130 could not link in the first
 *     place; the 80 real losses are all under \Console\, and console commands are
 *     on no hot path - `fpm` never touches them in a request, and `queue` boots
 *     them once per container and then runs for up to --max-time=3600. A
 *     consumer whose workload IS artisan-heavy restates the list without this
 *     entry. Adding vendor/symfony back instead was measured and rejected: 153
 *     warnings for +12.5 MB.
 *   - Application code is deliberately out too. Consumers who want it point
 *     LARAOCI_PRELOAD_PATHS at their own `app` directory - the variable REPLACES
 *     the list, so an append means restating the defaults.
 *
 * THE ERROR HANDLER DOES NOT DO WHAT §7.7 SAYS IT DOES. Its stated purpose is to
 * swallow the benign "Can't preload unlinked class" warnings, and it CANNOT:
 * those are emitted by opcache's LINK phase, which runs after this script has
 * returned and after restore_error_handler() - measured 2026-07-31, they arrive
 * on stderr strictly AFTER the line this script logs. A userland handler is not
 * installed at that point and could not be.
 *
 * What it does do is suppress warnings raised DURING opcache_compile_file(), so
 * it is kept - but the startup log is not clean, and pretending otherwise sends
 * the next reader hunting for a bug in the handler. With the §6.4 defaults on a
 * Laravel 13 tree it is 176 warnings, ~48 KB, once per container start.
 *
 * The try/catch around the compile is a different mechanism and does work: it
 * keeps a broken file in the tree from taking the process with it. Measured on
 * 8.3/8.4/8.5, a file containing `<?php class Broken {` is counted as skipped
 * and the process starts clean.
 *
 * ---------------------------------------------------------------------------
 * THE LAST LINE IS error_log(), AND IT MUST STAY error_log(). MEASURED
 * 2026-07-31 on 8.3/8.4/8.5, CLI and a non-root FPM master:
 *
 *   fwrite(STDERR, ...)                  Fatal error: Undefined constant
 *                                        "STDERR", EXIT 1. STDIN/STDOUT/STDERR
 *                                        are registered by the SAPI AFTER
 *                                        opcache runs this file, so they do not
 *                                        exist here. An uncaught Error during
 *                                        preload ABORTS STARTUP - the FPM master
 *                                        refuses to start. This is what spec
 *                                        §7.7 printed (corrected, D32).
 *   fopen('php://stderr', 'wb')          EXIT 255, SILENTLY. No message, no
 *                                        startup. Opening the wrapper is enough;
 *                                        closing it does not help. The obvious
 *                                        "fix", and the worst of the failures.
 *   file_put_contents('/proc/self/fd/2') Warning: failed to open stream.
 *                                        Survives, logs nothing.
 *   echo                                 Works, but lands on stdout, where the
 *                                        entrypoint's own log() uses stderr.
 *   error_log(...)                       Works. stderr, exit 0, everywhere.
 *
 * The cost is the "[date] " prefix that error_log = /proc/self/fd/2 (§6.5) adds.
 * Everything that reads this line matches it as a SUBSTRING for that reason.
 */

declare(strict_types=1);

$root = getenv('LARAOCI_PRELOAD_ROOT') ?: '/var/www/html';
$paths = getenv('LARAOCI_PRELOAD_PATHS')
    ?: 'vendor/laravel/framework/src/Illuminate,vendor/composer';
$ignore = getenv('LARAOCI_PRELOAD_IGNORE')
    ?: '/tests/,/Tests/,/stubs/,/Stubs/,/Testing/,/migrations/,/resources/,/Console/';

$ignores = array_filter(explode(',', $ignore));
$compiled = $skipped = 0;

// Suppresses warnings raised DURING opcache_compile_file(). It does NOT suppress
// "Can't preload unlinked class" - see the header block; those come from the link
// phase, after this script returns.
set_error_handler(static fn () => true);

foreach (array_filter(explode(',', $paths)) as $relative) {
    $dir = rtrim($root, '/').'/'.trim($relative, '/');
    if (! is_dir($dir)) {
        continue;
    }

    $files = new RegexIterator(
        new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)
        ),
        '/\.php$/'
    );

    foreach ($files as $file) {
        $path = $file->getPathname();

        foreach ($ignores as $needle) {
            if (str_contains($path, $needle)) {
                $skipped++;
                continue 2;
            }
        }

        try {
            opcache_compile_file($path) ? $compiled++ : $skipped++;
        } catch (Throwable) {
            $skipped++;
        }
    }
}

restore_error_handler();

// NOT fwrite(STDERR, ...) and NOT php://stderr - see the header block. This is
// the only mechanism measured to survive preload AND reach stderr. error_log()
// appends its own newline, so PHP_EOL is gone with the constant.
error_log(sprintf('laraoci: preloaded %d files, skipped %d', $compiled, $skipped));
