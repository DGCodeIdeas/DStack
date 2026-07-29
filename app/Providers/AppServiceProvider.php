<?php

namespace App\Providers;

use Illuminate\Support\ServiceProvider;
use App\Services\DockerComposeService;
use App\Services\VhostService;
use App\Services\SslService;
use App\Services\RdsTunnelService;
use App\Services\LogService;
use App\Services\BackupService;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(DockerComposeService::class);
        $this->app->singleton(VhostService::class);
        $this->app->singleton(SslService::class);
        $this->app->singleton(RdsTunnelService::class);
        $this->app->singleton(LogService::class);
        $this->app->singleton(BackupService::class);
    }

    public function boot(): void
    {
        //
    }
}