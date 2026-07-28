<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/*
| Exists so that `php artisan migrate` has application work to do beyond
| Laravel's own framework tables. LOCI-029 asserts that a migration runs
| successfully from the cli image against a writable sqlite file; a run that
| only created framework tables would still pass while proving less.
*/
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('widgets', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('widgets');
    }
};
