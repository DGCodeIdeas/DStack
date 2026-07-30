<?php

namespace Tests\Feature;

use App\Services\DockerComposeService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class ServicesStopCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.compose_file', 'docker-compose.yml');
        Config::set('dstack.env_file', '.env');
    }

    public function test_stop_service_exits_zero_on_success(): void
    {
        $service = $this->createMock(DockerComposeService::class);
        $service->method('stop')->with('nginx')->willReturn(['success' => true, 'message' => 'Service stopped']);
        $this->app->instance(DockerComposeService::class, $service);

        $result = $this->artisan('dstack:services:stop', ['service' => 'nginx']);
        $result->assertExitCode(0);
    }

    public function test_stop_service_exits_one_on_failure(): void
    {
        $service = $this->createMock(DockerComposeService::class);
        $service->method('stop')->with('nginx')->willReturn(['success' => false, 'message' => 'Failed to stop']);
        $this->app->instance(DockerComposeService::class, $service);

        $result = $this->artisan('dstack:services:stop', ['service' => 'nginx']);
        $result->assertExitCode(1);
    }
}
