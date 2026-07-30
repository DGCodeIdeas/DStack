<?php

namespace Tests\Feature;

use App\Services\RdsTunnelService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class RdsStatusCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.tunnel_pid_file', '/tmp/dstack/tunnel.pid');
    }

    public function test_rds_status_exits_zero(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('getStatus')->willReturn([
            'connected' => false,
            'local_port' => null,
            'rds_host' => null,
            'rds_port' => null,
        ]);
        $this->app->instance(RdsTunnelService::class, $tunnel);

        $result = $this->artisan('dstack:rds:status');
        $result->assertExitCode(0);
    }
}
