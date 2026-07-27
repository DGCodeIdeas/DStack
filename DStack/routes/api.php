<?php

use App\Http\Controllers\HealthController;
use App\Http\Controllers\DashboardController;
use App\Http\Controllers\ServiceController;
use App\Http\Controllers\VhostController;
use App\Http\Controllers\SslController;
use App\Http\Controllers\RdsTunnelController;
use App\Http\Controllers\LogController;
use App\Http\Controllers\BackupController;

Route::get('/health', [HealthController::class, 'index']);

Route::get('/services', [ServiceController::class, 'index']);
Route::post('/services/{service}/{action}', [ServiceController::class, 'action']);

Route::get('/vhosts', [VhostController::class, 'index']);
Route::post('/vhosts', [VhostController::class, 'store']);
Route::delete('/vhosts/{domain}', [VhostController::class, 'destroy']);

Route::get('/ssl', [SslController::class, 'index']);
Route::post('/ssl/local', [SslController::class, 'createLocal']);
Route::post('/ssl/letsencrypt', [SslController::class, 'createLetsEncrypt']);

Route::post('/rds/tunnel/start', [RdsTunnelController::class, 'start']);
Route::post('/rds/tunnel/stop', [RdsTunnelController::class, 'stop']);
Route::get('/rds/tunnel/status', [RdsTunnelController::class, 'status']);

Route::get('/logs/{service}', [LogController::class, 'index']);
Route::get('/logs/{service}/stream', [LogController::class, 'stream']);

Route::post('/backup', [BackupController::class, 'create']);
Route::get('/backups', [BackupController::class, 'index']);
Route::post('/restore', [BackupController::class, 'restore']);