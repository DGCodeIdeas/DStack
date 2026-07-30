<?php

namespace Tests\Feature;

use App\Services\VhostService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class VhostsCreateCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.vhosts_dir', '/tmp/dstack/vhosts');
        Config::set('dstack.projects_dir', '/tmp/projects');
        Config::set('dstack.nginx_container', 'nginx');
    }

    public function test_create_vhost_exits_zero_on_success(): void
    {
        $vhost = $this->createMock(VhostService::class);
        $vhost->method('create')->with('example.local', null, 'php')->willReturn([
            'success' => true,
            'domain' => 'example.local',
            'root' => '/tmp/projects/example.local',
            'config_path' => '/tmp/dstack/vhosts/example.local.conf',
            'warnings' => [],
        ]);
        $this->app->instance(VhostService::class, $vhost);

        $result = $this->artisan('dstack:vhosts:create', ['domain' => 'example.local']);
        $result->assertExitCode(0);
    }

    public function test_create_vhost_exits_one_on_failure(): void
    {
        $vhost = $this->createMock(VhostService::class);
        $vhost->method('create')->willReturn([
            'success' => false,
            'domain' => 'invalid',
            'root' => null,
            'config_path' => null,
            'warnings' => ['domain is required and must be a string'],
        ]);
        $this->app->instance(VhostService::class, $vhost);

        $result = $this->artisan('dstack:vhosts:create', ['domain' => 'invalid']);
        $result->assertExitCode(1);
    }

    public function test_create_vhost_passes_root_and_framework_options(): void
    {
        $vhost = $this->createMock(VhostService::class);
        $vhost->method('create')->with('example.local', '/custom/root', 'laravel')->willReturn([
            'success' => true,
            'domain' => 'example.local',
            'root' => '/custom/root',
            'config_path' => '/tmp/dstack/vhosts/example.local.conf',
            'warnings' => [],
        ]);
        $this->app->instance(VhostService::class, $vhost);

        $result = $this->artisan('dstack:vhosts:create', [
            'domain' => 'example.local',
            '--root' => '/custom/root',
            '--framework' => 'laravel',
        ]);
        $result->assertExitCode(0);
    }
}
