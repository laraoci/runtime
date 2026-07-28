<?php

use Illuminate\Support\Facades\Route;

/*
| The four smoke routes. Each one exists to make a single container-level claim
| observable over HTTP; none of them is application logic worth reading as an
| example. The route names and response shapes are a contract - Tasks 11-13 and
| M3's LOCI-036/037 assert on these exact strings.
*/

/*
| LOCI-029 step 3. Asserts the BUILD produced something, not merely that PHP
| answers. The marker alone would return 200 from an image where `npm run build`
| silently did nothing, so the response also carries the hashed asset filename
| read out of vite's manifest - which only exists after a real build.
|
| A missing or empty manifest is a 500 with a message that names the cause,
| because "the build step did not run" and "the app is broken" are different
| failures and the smoke log should not make the reader guess.
*/
Route::get('/', function () {
    $manifest = public_path('build/manifest.json');

    if (! is_file($manifest)) {
        abort(500, 'vite manifest is missing - `npm run build` did not run');
    }

    $entries = json_decode((string) file_get_contents($manifest), true);
    $asset = $entries['resources/js/app.js']['file'] ?? null;

    if ($asset === null) {
        abort(500, 'vite manifest has no entry for resources/js/app.js');
    }

    return response("laraoci-fixture-ok asset={$asset}\n")
        ->header('Content-Type', 'text/plain');
});

/*
| LOCI-030 - the single most consequential assertion in the suite. With FPM's
| default clear_env = yes, a Laravel app sees NONE of the container's
| environment and silently falls back to defaults; the value below would read
| MISSING while everything else stayed green.
|
| env() is called DIRECTLY, not config(), and the fixture deliberately never
| runs `config:cache`. Both matter: reading through a cached config would return
| the value baked at cache time and prove nothing about the running container's
| environment, which is precisely the failure mode being tested.
*/
Route::get('/env-echo', function () {
    return response('LARAOCI_SMOKE_VALUE='.env('LARAOCI_SMOKE_VALUE', 'MISSING')."\n")
        ->header('Content-Type', 'text/plain');
});

/*
| LOCI-031, first half. imagick through the FPM SAPI rather than the CLI one the
| structure tests use - same extension, different process model, and the
| MAGICK_THREAD_LIMIT=1 the image sets exists because twenty FPM children each
| opening an OpenMP pool will thrash a CPU-limited container.
|
| The image is created in memory rather than read from disk so the route tests
| the codec path and nothing about the filesystem.
*/
Route::get('/imagick/resize', function () {
    $source = new Imagick();
    $source->newImage(200, 200, new ImagickPixel('red'));
    $source->setImageFormat('jpeg');
    $blob = $source->getImageBlob();
    $source->clear();

    $image = new Imagick();
    $image->readImageBlob($blob);
    $image->resizeImage(50, 50, Imagick::FILTER_LANCZOS, 1);
    $dimensions = $image->getImageWidth().'x'.$image->getImageHeight();
    $image->clear();

    return response("resized={$dimensions}\n")
        ->header('Content-Type', 'text/plain');
});

/*
| LOCI-031, second half. The hardened policy (D13) asserted through FPM.
|
| The probe file MUST exist before readImage() is called. A missing path throws
| ImagickException too - with "unable to open image" - so a test that only
| checked for an exception would pass on an image with no policy at all. The
| caller asserts on the DENIED message, not merely on the failure.
|
| Deliberately not the @file indirect-read form: ImageMagick 7 rejects those
| with "no decode delegate" before the path policy is ever consulted, which the
| M1 runtime work established. PDF, MVG and TEXT do go through the coder policy.
*/
Route::get('/imagick/policy/{coder}', function (string $coder) {
    $coder = strtoupper($coder);

    if (! in_array($coder, ['PDF', 'MVG', 'TEXT'], true)) {
        abort(400, "unsupported coder {$coder}");
    }

    $probe = storage_path('app/policy-probe');
    file_put_contents($probe, "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n");

    try {
        (new Imagick())->readImage($coder.':'.$probe);

        return response("ALLOWED\n")->header('Content-Type', 'text/plain');
    } catch (ImagickException $e) {
        return response('DENIED:'.$e->getMessage()."\n")
            ->header('Content-Type', 'text/plain');
    } finally {
        @unlink($probe);
    }
});
