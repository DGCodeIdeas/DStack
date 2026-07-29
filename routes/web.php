<?php

use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Web Routes
|--------------------------------------------------------------------------
|
| The SPA fallback route. All client-side routing is handled by the
| JavaScript bundle; this route simply serves the Blade view that
| mounts the panel.
|
*/

Route::get('/', [App\Http\Controllers\DashboardController::class, 'index']);

Route::get('/{any}', [App\Http\Controllers\DashboardController::class, 'index'])
    ->where('any', '.*');