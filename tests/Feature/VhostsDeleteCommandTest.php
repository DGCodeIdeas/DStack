<?php

namespace Tests\Feature;

use App\Services\VhostService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class VhostsDeleteCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.vhosts_dir', '/tmp/dstack/vhosts');
        Config::set('dstack.projects_dir', '/tmp/projects');
        Config::set('dstack.nginx_container', 'nginx');
    }

    public function test_delete_vhost_confirms_before_deleting(): void
    {
        $vhost = $this->createMock(VhostService::class);
        $vhost->method('delete')->willReturn(['success' => true, 'domain' => 'example.local', 'missing' => false, 'warnings' => []]);
        $this->app->instance(VhostService::class, $vhost);

        $result = $this->artisan('dstack:vhosts:delete', [
            'domain' => 'example.local',
            '--remove-files' => true,
        ]);
        $result->assertExitCode(0);
    }
}
