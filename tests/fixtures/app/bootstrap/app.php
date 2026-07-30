<?php

use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;

// The scheduled task is registered in routes/console.php with the Schedule
// facade rather than through a withSchedule() closure here. Both work; the
// facade form is what a current `laravel new` produces, and it keeps the task
// next to the console routes the plan's file tree puts it in. Nothing else in
// this file is customised - Laravel merges its own defaults for every config
// file the fixture does not ship, which is why config/ holds one file.
return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
    )
    ->withMiddleware(function (Middleware $middleware) {
        //
    })
    ->withExceptions(function (Exceptions $exceptions) {
        //
    })->create();
