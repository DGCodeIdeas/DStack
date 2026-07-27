<?php

namespace Tests\Feature;

use App\Services\RdsTunnelService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class RdsTunnelControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_start_returns_400_for_missing_params(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('connect')->willReturn([
            'success' => false,
            'message' => 'ec2_host must be a non-empty string',
        ]);

        $this->app->instance(RdsTunnelService::class, $tunnel);

        $response = $this->postJson('/api/rds/tunnel/start', [
            'ec2_host' => '',
            'ec2_user' => 'ubuntu',
            'ec2_key_path' => '/tmp/key',
            'rds_host' => 'rds.example.com',
        ]);

        $response->assertStatus(400);
    }

    public function test_stop_returns_success(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('disconnect')->willReturn([
            'success' => true,
            'message' => 'Tunnel disconnected',
        ]);

        $this->app->instance(RdsTunnelService::class, $tunnel);

        $response = $this->postJson('/api/rds/tunnel/stop');

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'message' => 'Tunnel disconnected',
        ]);
    }

    public function test_status_returns_disconnected_when_no_tunnel(): void
    {
        $tunnel = $this->createMock(RdsTunnelService::class);
        $tunnel->method('getStatus')->willReturn([
            'connected' => false,
            'local_port' => null,
            'rds_host' => null,
            'rds_port' => null,
        ]);

        $this->app->instance(RdsTunnelService::class, $tunnel);

        $response = $this->getJson('/api/rds/tunnel/status');

        $response->assertStatus(200);
        $response->assertJson([
            'connected' => false,
        ]);
    }
}