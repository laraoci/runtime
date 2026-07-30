<?php

/*
| The ONLY config file the fixture ships. Laravel merges its own defaults for
| every file that is absent, so config/app.php, config/queue.php and the rest
| are deliberately not here - a copy of a framework default is a copy that can
| drift silently against three PHP versions.
|
| This one is present because two of its values are load-bearing for the smoke
| suite: sqlite as the default connection (no database service to wait on) and
| an ABSOLUTE database path. A relative path resolves against the working
| directory, which differs between `php artisan` on the cli image and an FPM
| worker serving a request - the same fixture would then use two different
| database files and `migrate` would appear not to have run.
*/

return [

    'default' => env('DB_CONNECTION', 'sqlite'),

    'connections' => [

        'sqlite' => [
            'driver' => 'sqlite',
            'url' => env('DB_URL'),
            'database' => env('DB_DATABASE', database_path('database.sqlite')),
            'prefix' => '',
            'foreign_key_constraints' => env('DB_FOREIGN_KEYS', true),
            'busy_timeout' => null,
            'journal_mode' => null,
            'synchronous' => null,
        ],

    ],

    'migrations' => [
        'table' => 'migrations',
        'update_date_on_publish' => true,
    ],

];
