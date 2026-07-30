<?php

namespace Tests\Feature;

use App\Services\VhostService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class VhostsListCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.vhosts_dir', '/tmp/dstack/vhosts');
        Config::set('dstack.projects_dir', '/tmp/projects');
        Config::set('dstack.nginx_container', 'nginx');
    }

    public function test_list_vhosts_outputs_table(): void
    {
        $vhost = $this->createMock(VhostService::class);
        $vhost->method('listAll')->willReturn([]);
        $this->app->instance(VhostService::class, $vhost);

        $result = $this->artisan('dstack:vhosts:list');
        $result->assertExitCode(0);
        $result->expectsOutput('No virtual hosts found.');
    }
}
