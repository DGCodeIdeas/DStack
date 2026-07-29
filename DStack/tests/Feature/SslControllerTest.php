<?php

namespace Tests\Feature;

use App\Services\SslService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class SslControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_index_returns_cert_list(): void
    {
        $ssl = $this->createMock(SslService::class);
        $ssl->method('listCerts')->willReturn([
            ['domain' => 'example.local', 'cert_path' => '/opt/dstack-panel/docker/ssl/example.local.pem', 'key_path' => '/opt/dstack-panel/docker/ssl/example.local-key.pem', 'exists' => true],
        ]);

        $this->app->instance(SslService::class, $ssl);

        $response = $this->getJson('/api/ssl');

        $response->assertStatus(200);
        $response->assertJson([
            ['domain' => 'example.local', 'exists' => true],
        ]);
    }

    public function test_create_local_returns_success(): void
    {
        $ssl = $this->createMock(SslService::class);
        $ssl->method('createMkcert')->willReturn([
            'success' => true,
            'domain' => 'test.local',
            'cert_path' => '/opt/dstack-panel/docker/ssl/test.local.pem',
            'key_path' => '/opt/dstack-panel/docker/ssl/test.local-key.pem',
            'message' => 'Certificate created for test.local via mkcert',
        ]);

        $this->app->instance(SslService::class, $ssl);

        $response = $this->postJson('/api/ssl/local', [
            'domain' => 'test.local',
        ]);

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'domain' => 'test.local',
        ]);
    }

    public function test_create_letsencrypt_returns_success(): void
    {
        $ssl = $this->createMock(SslService::class);
        $ssl->method('createLetsEncrypt')->willReturn([
            'success' => true,
            'domain' => 'example.com',
            'cert_path' => '/opt/dstack-panel/docker/ssl/example.com.pem',
            'key_path' => '/opt/dstack-panel/docker/ssl/example.com-key.pem',
            'message' => "Certificate created for example.com via Let's Encrypt",
        ]);

        $this->app->instance(SslService::class, $ssl);

        $response = $this->postJson('/api/ssl/letsencrypt', [
            'domain' => 'example.com',
            'email' => 'admin@example.com',
            'mode' => 'standalone',
        ]);

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'domain' => 'example.com',
        ]);
    }
}