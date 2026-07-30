<?php

namespace Tests\Feature;

use App\Services\DockerComposeService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class ServicesRestartCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.compose_file', 'docker-compose.yml');
        Config::set('dstack.env_file', '.env');
    }

    public function test_restart_service_exits_zero_on_success(): void
    {
        $service = $this->createMock(DockerComposeService::class);
        $service->method('restart')->with('nginx')->willReturn(['success' => true, 'message' => 'Service restarted']);
        $this->app->instance(DockerComposeService::class, $service);

        $result = $this->artisan('dstack:services:restart', ['service' => 'nginx']);
        $result->assertExitCode(0);
    }

    public function test_restart_service_exits_one_on_failure(): void
    {
        $service = $this->createMock(DockerComposeService::class);
        $service->method('restart')->with('nginx')->willReturn(['success' => false, 'message' => 'Failed to restart']);
        $this->app->instance(DockerComposeService::class, $service);

        $result = $this->artisan('dstack:services:restart', ['service' => 'nginx']);
        $result->assertExitCode(1);
    }
}
