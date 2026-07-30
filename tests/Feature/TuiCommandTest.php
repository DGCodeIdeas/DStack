<?php

namespace Tests\Feature;

use App\Services\BackupService;
use App\Services\DockerComposeService;
use App\Services\LogService;
use App\Services\RdsTunnelService;
use App\Services\SslService;
use App\Services\VhostService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class TuiCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.compose_file', 'docker-compose.yml');
        Config::set('dstack.env_file', '.env');
        Config::set('dstack.vhosts_dir', '/tmp/dstack/vhosts');
        Config::set('dstack.projects_dir', '/tmp/projects');
        Config::set('dstack.nginx_container', 'nginx');
        Config::set('dstack.ssl_dir', '/tmp/dstack/ssl');
        Config::set('dstack.tunnel_pid_file', '/tmp/dstack/tunnel.pid');
        Config::set('dstack.backups_dir', '/tmp/dstack/backups');
    }

    public function test_tui_exits_zero_on_exit_choice(): void
    {
        $docker = $this->createMock(DockerComposeService::class);
        $docker->method('getAllStatus')->willReturn([]);

        $vhost = $this->createMock(VhostService::class);
        $ssl = $this->createMock(SslService::class);
        $tunnel = $this->createMock(RdsTunnelService::class);
        $log = $this->createMock(LogService::class);
        $backup = $this->createMock(BackupService::class);

        $this->app->instance(DockerComposeService::class, $docker);
        $this->app->instance(VhostService::class, $vhost);
        $this->app->instance(SslService::class, $ssl);
        $this->app->instance(RdsTunnelService::class, $tunnel);
        $this->app->instance(LogService::class, $log);
        $this->app->instance(BackupService::class, $backup);

        $result = $this->artisan('dstack:tui')
            ->expectsChoice('DStack Management', 'Exit', ['Dashboard', 'Vhosts', 'SSL', 'RDS Tunnel', 'Logs', 'Backups', 'Exit']);
        $result->assertExitCode(0);
    }
}
