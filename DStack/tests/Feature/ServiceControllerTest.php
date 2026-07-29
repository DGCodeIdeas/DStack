<?php

namespace Tests\Feature;

use App\Services\DockerComposeService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class ServiceControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_index_returns_service_status(): void
    {
        $docker = $this->createMock(DockerComposeService::class);
        $docker->method('getAllStatus')->willReturn([
            'nginx' => ['status' => 'Up 2 hours', 'state' => 'running', 'health' => 'healthy'],
        ]);

        $this->app->instance(DockerComposeService::class, $docker);

        $response = $this->getJson('/api/services');

        $response->assertStatus(200);
        $response->assertJson([
            'nginx' => [
                'status' => 'Up 2 hours',
                'state' => 'running',
                'health' => 'healthy',
            ],
        ]);
    }

    public function test_action_start_returns_success_with_status(): void
    {
        $docker = $this->createMock(DockerComposeService::class);
        $docker->method('start')->willReturn(['success' => true, 'message' => 'OK']);
        $docker->method('getAllStatus')->willReturn([
            'nginx' => ['status' => 'Up 2 hours', 'state' => 'running'],
        ]);

        $this->app->instance(DockerComposeService::class, $docker);

        $response = $this->postJson('/api/services/nginx/start');

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'message' => 'OK',
        ]);
        $this->assertArrayHasKey('status', $response->json());
    }

    public function test_action_invalid_service_returns_400(): void
    {
        $docker = $this->createMock(DockerComposeService::class);

        $this->app->instance(DockerComposeService::class, $docker);

        $response = $this->postJson('/api/services/invalid/start');

        $response->assertStatus(400);
        $response->assertJson([
            'success' => false,
        ]);
    }

    public function test_action_invalid_action_returns_400(): void
    {
        $docker = $this->createMock(DockerComposeService::class);

        $this->app->instance(DockerComposeService::class, $docker);

        $response = $this->postJson('/api/services/nginx/invalid');

        $response->assertStatus(400);
        $response->assertJson([
            'success' => false,
        ]);
    }
}