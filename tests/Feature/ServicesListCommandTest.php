<?php

namespace Tests\Feature;

use App\Services\DockerComposeService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class ServicesListCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.compose_file', 'docker-compose.yml');
        Config::set('dstack.env_file', '.env');
    }

    public function test_list_services_outputs_table(): void
    {
        $service = new DockerComposeService;
        $this->app->instance(DockerComposeService::class, $service);

        $result = $this->artisan('dstack:services:list');
        $result->assertExitCode(0);
    }

    public function test_list_services_with_no_services_shows_message(): void
    {
        $service = $this->createMock(DockerComposeService::class);
        $service->method('getAllStatus')->willReturn([]);
        $this->app->instance(DockerComposeService::class, $service);

        $result = $this->artisan('dstack:services:list');
        $result->assertExitCode(0);
        $result->expectsOutput('No services found.');
    }
}
