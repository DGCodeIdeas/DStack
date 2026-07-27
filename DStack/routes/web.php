<?php

use Illuminate\Support\Facades\Route;

Route::get('/', [App\Http\Controllers\DashboardController::class, 'index']);

Route::get('/{any}', [App\Http\Controllers\DashboardController::class, 'index'])
    ->where('any', '^(?!assets($|/)|storage($|/)|build($|/)|favicon\.ico|robots\.txt).*$');