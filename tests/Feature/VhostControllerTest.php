<?php

namespace Tests\Feature;

use App\Services\VhostService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class VhostControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_index_returns_vhost_list(): void
    {
        $this->actingAsUser();

        $vhost = $this->createMock(VhostService::class);
        $vhost->method('listAll')->willReturn([
            ['domain' => 'example.local', 'framework' => 'php', 'root' => '/var/www/projects/example.local'],
        ]);

        $this->app->instance(VhostService::class, $vhost);

        $response = $this->getJson('/api/vhosts');

        $response->assertStatus(200);
        $response->assertJson([
            ['domain' => 'example.local', 'framework' => 'php'],
        ]);
    }

    public function test_store_creates_vhost(): void
    {
        $this->actingAsUser();

        $vhost = $this->createMock(VhostService::class);
        $vhost->method('create')->willReturn([
            'success' => true,
            'domain' => 'test.local',
            'root' => '/var/www/projects/test.local',
            'config_path' => '/opt/dstack-panel/docker/vhosts/test.local.conf',
            'warnings' => [],
        ]);

        $this->app->instance(VhostService::class, $vhost);

        $response = $this->postJson('/api/vhosts', [
            'domain' => 'test.local',
            'framework' => 'php',
        ]);

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'domain' => 'test.local',
        ]);
    }

    public function test_store_invalid_domain_returns_400(): void
    {
        $this->actingAsUser();

        $vhost = $this->createMock(VhostService::class);
        $vhost->method('create')->willReturn([
            'success' => false,
            'domain' => '',
            'warnings' => ['domain is required and must be a string'],
        ]);

        $this->app->instance(VhostService::class, $vhost);

        $response = $this->postJson('/api/vhosts', [
            'domain' => '',
        ]);

        $response->assertStatus(400);
    }

    public function test_destroy_returns_404_for_missing_vhost(): void
    {
        $this->actingAsUser();

        $vhost = $this->createMock(VhostService::class);
        $vhost->method('delete')->willReturn([
            'success' => false,
            'domain' => 'missing.local',
            'missing' => true,
            'warnings' => ['No vhost config found at /opt/dstack-panel/docker/vhosts/missing.local.conf'],
        ]);

        $this->app->instance(VhostService::class, $vhost);

        $response = $this->deleteJson('/api/vhosts/missing.local');

        $response->assertStatus(404);
        $response->assertJson([
            'success' => false,
            'missing' => true,
        ]);
    }

    public function test_destroy_returns_success(): void
    {
        $this->actingAsUser();

        $vhost = $this->createMock(VhostService::class);
        $vhost->method('delete')->willReturn([
            'success' => true,
            'domain' => 'test.local',
            'missing' => false,
            'removed_config' => '/opt/dstack-panel/docker/vhosts/test.local.conf',
            'warnings' => [],
        ]);

        $this->app->instance(VhostService::class, $vhost);

        $response = $this->deleteJson('/api/vhosts/test.local');

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'domain' => 'test.local',
        ]);
    }
}
