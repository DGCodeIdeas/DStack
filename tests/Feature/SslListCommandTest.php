<?php

namespace Tests\Feature;

use App\Services\SslService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class SslListCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.ssl_dir', '/tmp/dstack/ssl');
        Config::set('dstack.vhosts_dir', '/tmp/dstack/vhosts');
        Config::set('dstack.nginx_container', 'nginx');
    }

    public function test_list_certs_outputs_table(): void
    {
        $ssl = $this->createMock(SslService::class);
        $ssl->method('listCerts')->willReturn([]);
        $this->app->instance(SslService::class, $ssl);

        $result = $this->artisan('dstack:ssl:list');
        $result->assertExitCode(0);
        $result->expectsOutput('No SSL certificates found.');
    }
}
