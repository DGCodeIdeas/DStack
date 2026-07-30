<?php

namespace Tests\Feature;

use App\Services\LogService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class LogsCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.compose_file', 'docker-compose.yml');
        Config::set('dstack.env_file', '.env');
    }

    public function test_logs_exits_zero_on_success(): void
    {
        $log = $this->createMock(LogService::class);
        $log->method('getLogs')->with('nginx', 50)->willReturn([
            'success' => true,
            'message' => 'OK',
            'service' => 'nginx',
            'lines' => ['nginx | log line 1', 'nginx | log line 2'],
            'entries' => [],
            'raw' => '',
            'truncated' => false,
        ]);
        $this->app->instance(LogService::class, $log);

        $result = $this->artisan('dstack:logs', ['service' => 'nginx']);
        $result->assertExitCode(0);
    }

    public function test_logs_exits_one_on_unknown_service(): void
    {
        $log = $this->createMock(LogService::class);
        $log->method('getLogs')->willReturn([
            'success' => false,
            'message' => "Unknown service 'unknown'. Valid targets: nginx, php, mysql, redis, phpmyadmin, all",
            'service' => 'unknown',
            'lines' => [],
            'entries' => [],
            'raw' => '',
            'truncated' => false,
        ]);
        $this->app->instance(LogService::class, $log);

        $result = $this->artisan('dstack:logs', ['service' => 'unknown']);
        $result->assertExitCode(1);
    }
}
