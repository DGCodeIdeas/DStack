<?php

namespace Tests\Unit;

use App\Services\SslService;
use PHPUnit\Framework\TestCase;

class SslServiceTest extends TestCase
{
    public function testRenderSslServerBlock(): void
    {
        $result = SslService::renderSslServerBlock(
            'example.local',
            '/etc/nginx/ssl/example.local.pem',
            '/etc/nginx/ssl/example.local-key.pem',
            '/var/www/projects/example.local',
            'try_files $uri $uri/ =404;'
        );

        $this->assertStringContainsString('server_name example.local;', $result);
        $this->assertStringContainsString('ssl_certificate /etc/nginx/ssl/example.local.pem;', $result);
        $this->assertStringContainsString('ssl_certificate_key /etc/nginx/ssl/example.local-key.pem;', $result);
        $this->assertStringContainsString('ssl_protocols TLSv1.2 TLSv1.3;', $result);
        $this->assertStringContainsString('ssl_prefer_server_ciphers on;', $result);
        $this->assertStringContainsString('fastcgi_pass php:9000;', $result);
    }

    public function testRemoveHttpsBlock(): void
    {
        $content = <<<'NGINX'
server {
    listen 80;
    server_name example.local;
    root /var/www/example;
}
server {
    listen 443 ssl;
    server_name example.local;
    root /var/www/example;
}
NGINX;

        $result = SslService::removeHttpsBlock($content);

        $this->assertStringNotContainsString('listen 443', $result);
        $this->assertStringContainsString('listen 80', $result);
    }

    public function testInjectHttpRedirect(): void
    {
        $content = <<<'NGINX'
server {
    listen 80;
    server_name example.local;
    root /var/www/example;
    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX;

        $result = SslService::injectHttpRedirect($content, 'example.local');

        $this->assertStringContainsString('return 301 https://$host$request_uri;', $result);
    }

    public function testInjectHttpRedirectNoMatch(): void
    {
        $content = <<<'NGINX'
server {
    listen 80;
    server_name other.local;
    root /var/www/other;
}
NGINX;

        $result = SslService::injectHttpRedirect($content, 'example.local');

        $this->assertStringNotContainsString('return 301', $result);
    }
}