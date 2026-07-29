<?php

use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| API Routes
|--------------------------------------------------------------------------
|
| All /api/* routes for the DStack panel. Prefixed automatically by
| RouteServiceProvider with /api.
|
*/

// Health check
Route::get('/health', [App\Http\Controllers\HealthController::class, 'index']);

// Services
Route::get('/services', [App\Http\Controllers\ServiceController::class, 'index']);
Route::post('/services/{service}/{action}', [App\Http\Controllers\ServiceController::class, 'action']);

// Virtual hosts
Route::get('/vhosts', [App\Http\Controllers\VhostController::class, 'index']);
Route::post('/vhosts', [App\Http\Controllers\VhostController::class, 'store']);
Route::delete('/vhosts/{domain}', [App\Http\Controllers\VhostController::class, 'destroy']);

// SSL certificates
Route::get('/ssl', [App\Http\Controllers\SslController::class, 'index']);
Route::get('/ssl/certs', [App\Http\Controllers\SslController::class, 'index']);
Route::post('/ssl/local', [App\Http\Controllers\SslController::class, 'createLocal']);
Route::post('/ssl/letsencrypt', [App\Http\Controllers\SslController::class, 'createLetsEncrypt']);

// RDS tunnel
Route::post('/rds/tunnel/start', [App\Http\Controllers\RdsTunnelController::class, 'start']);
Route::post('/rds/tunnel/stop', [App\Http\Controllers\RdsTunnelController::class, 'stop']);
Route::get('/rds/tunnel/status', [App\Http\Controllers\RdsTunnelController::class, 'status']);

// Logs
Route::get('/logs/{service}', [App\Http\Controllers\LogController::class, 'index']);
Route::get('/logs/{service}/stream', [App\Http\Controllers\LogController::class, 'stream']);

// Backups
Route::post('/backup', [App\Http\Controllers\BackupController::class, 'create']);
Route::get('/backups', [App\Http\Controllers\BackupController::class, 'index']);
Route::post('/restore', [App\Http\Controllers\BackupController::class, 'restore']);