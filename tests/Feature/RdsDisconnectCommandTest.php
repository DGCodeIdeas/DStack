<?php

namespace Tests\Feature;

use App\Services\RdsTunnelService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class RdsDisconnectCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.tunnel_pid_file', '/tmp/dstack/tunnel.pid');
    }

    public function test_disconnect_exits_zero_on_success(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('disconnect')->willReturn(['success' => true, 'message' => 'Tunnel disconnected']);
        $this->app->instance(RdsTunnelService::class, $tunnel);

        $result = $this->artisan('dstack:rds:disconnect');
        $result->assertExitCode(0);
    }
}
