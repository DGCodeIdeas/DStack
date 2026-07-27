<?php

namespace Tests\Feature;

use App\Services\LogService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class LogControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_index_returns_logs(): void
    {
        $log = $this->createMock(LogService::class);
        $log->method('getLogs')->with('nginx', 50)->willReturn([
            'success' => true,
            'message' => 'OK',
            'service' => 'nginx',
            'lines' => ['nginx-1 | 192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] "GET / HTTP/1.1" 200'],
            'entries' => [['raw' => 'nginx-1 | 192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] "GET / HTTP/1.1" 200', 'service' => 'nginx', 'message' => '192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] "GET / HTTP/1.1" 200']],
            'raw' => 'nginx-1 | 192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] "GET / HTTP/1.1" 200',
            'truncated' => false,
        ]);

        $this->app->instance(LogService::class, $log);

        $response = $this->getJson('/api/logs/nginx?lines=50');

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'service' => 'nginx',
        ]);
    }

    public function test_index_unknown_service_returns_400(): void
    {
        $log = $this->createMock(LogService::class);
        $log->method('getLogs')->willReturn([
            'success' => false,
            'message' => "Unknown service 'invalid'. Valid targets: nginx, php, mysql, redis, phpmyadmin, all",
            'service' => 'invalid',
            'lines' => [],
            'entries' => [],
            'raw' => '',
            'truncated' => false,
        ]);

        $this->app->instance(LogService::class, $log);

        $response = $this->getJson('/api/logs/invalid');

        $response->assertStatus(400);
    }

    public function test_stream_returns_logs(): void
    {
        $log = $this->createMock(LogService::class);
        $log->method('getLogs')->willReturn([
            'success' => true,
            'message' => 'OK',
            'service' => 'nginx',
            'lines' => ['nginx-1 | test log line'],
            'entries' => [],
            'raw' => 'nginx-1 | test log line',
            'truncated' => false,
        ]);

        $this->app->instance(LogService::class, $log);

        $response = $this->getJson('/api/logs/nginx/stream');

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
        ]);
    }
}