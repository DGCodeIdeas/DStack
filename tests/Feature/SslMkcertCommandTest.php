<?php

namespace Tests\Feature;

use App\Services\SslService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class SslMkcertCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.ssl_dir', '/tmp/dstack/ssl');
        Config::set('dstack.vhosts_dir', '/tmp/dstack/vhosts');
        Config::set('dstack.nginx_container', 'nginx');
    }

    public function test_mkcert_exits_zero_on_success(): void
    {
        $ssl = $this->createMock(SslService::class);
        $ssl->method('createMkcert')->willReturn([
            'success' => true,
            'domain' => 'example.local',
            'message' => 'Certificate created for example.local via mkcert',
        ]);
        $this->app->instance(SslService::class, $ssl);

        $result = $this->artisan('dstack:ssl:mkcert', ['domain' => 'example.local']);
        $result->assertExitCode(0);
    }

    public function test_mkcert_exits_one_on_failure(): void
    {
        $ssl = $this->createMock(SslService::class);
        $ssl->method('createMkcert')->willReturn([
            'success' => false,
            'domain' => 'example.local',
            'message' => 'mkcert not installed',
        ]);
        $this->app->instance(SslService::class, $ssl);

        $result = $this->artisan('dstack:ssl:mkcert', ['domain' => 'example.local']);
        $result->assertExitCode(1);
    }
}
