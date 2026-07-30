<?php

namespace Tests\Feature;

use App\Services\RdsTunnelService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class RdsConnectCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.tunnel_pid_file', '/tmp/dstack/tunnel.pid');
    }

    public function test_connect_rds_exits_zero_on_success(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('connect')->with('ec2.example.com', 'ubuntu', '/tmp/key.pem', 'rds.example.com', 3306, 3307)->willReturn([
            'success' => true,
            'message' => 'Tunnel established',
            'local_port' => 3307,
            'rds_host' => 'rds.example.com',
            'rds_port' => 3306,
        ]);
        $this->app->instance(RdsTunnelService::class, $tunnel);

        $result = $this->artisan('dstack:rds:connect', [
            'ec2-host' => 'ec2.example.com',
            'ec2-user' => 'ubuntu',
            'ec2-key-path' => '/tmp/key.pem',
            'rds-host' => 'rds.example.com',
            '--rds-port' => 3306,
            '--local-port' => 3307,
        ]);
        $result->assertExitCode(0);
    }

    public function test_connect_rds_exits_one_on_failure(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('connect')->willReturn([
            'success' => false,
            'message' => 'SSH tunnel failed',
            'local_port' => 3307,
            'rds_host' => 'rds.example.com',
            'rds_port' => 3306,
        ]);
        $this->app->instance(RdsTunnelService::class, $tunnel);

        $result = $this->artisan('dstack:rds:connect', [
            'ec2-host' => 'ec2.example.com',
            'ec2-user' => 'ubuntu',
            'ec2-key-path' => '/tmp/key.pem',
            'rds-host' => 'rds.example.com',
        ]);
        $result->assertExitCode(1);
    }
}
