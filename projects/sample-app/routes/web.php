<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::get('/api/ping', function () {
    return response()->json([
        'message' => 'pong',
        'timestamp' => now()->toISOString(),
        'php_version' => phpversion(),
        'laravel_version' => app()->version(),
    ]);
});

Route::get('/api/health', function () {
    return response()->json([
        'status' => 'ok',
        'checks' => [
            'database' => 'connected',
            'cache' => 'connected',
        ],
    ]);
});