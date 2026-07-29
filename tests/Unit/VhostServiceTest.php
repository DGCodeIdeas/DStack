<?php

namespace Tests\Unit;

use App\Services\VhostService;
use Tests\TestCase;

class VhostServiceTest extends TestCase
{
    public function test_validate_domain_valid(): void
    {
        [$ok, $err] = VhostService::validateDomain('example.local');
        $this->assertTrue($ok);
        $this->assertEquals('', $err);
    }

    public function test_validate_domain_with_subdomain(): void
    {
        [$ok, $err] = VhostService::validateDomain('api.example.com');
        $this->assertTrue($ok);
    }

    public function test_validate_domain_empty(): void
    {
        [$ok, $err] = VhostService::validateDomain('');
        $this->assertFalse($ok);
    }

    public function test_validate_domain_with_path_separator(): void
    {
        [$ok, $err] = VhostService::validateDomain('example.com/path');
        $this->assertFalse($ok);
    }

    public function test_validate_domain_with_dot_dot(): void
    {
        [$ok, $err] = VhostService::validateDomain('example..local');
        $this->assertFalse($ok);
    }

    public function test_validate_domain_with_trailing_hyphen(): void
    {
        [$ok, $err] = VhostService::validateDomain('-example.local');
        $this->assertFalse($ok);
    }

    public function test_validate_domain_with_trailing_hyphen_in_label(): void
    {
        [$ok, $err] = VhostService::validateDomain('example-.local');
        $this->assertFalse($ok);
    }

    public function test_render_vhost_php(): void
    {
        $vhost = new VhostService;
        $result = $vhost->renderVhost('test.local', '/var/www/projects/test.local', 'php');

        $this->assertStringContainsString('server_name test.local;', $result);
        $this->assertStringContainsString('root /var/www/projects/test.local;', $result);
        $this->assertStringContainsString('try_files $uri $uri/ =404;', $result);
    }

    public function test_render_vhost_laravel(): void
    {
        $vhost = new VhostService;
        $result = $vhost->renderVhost('app.local', '/var/www/projects/app.local/public', 'laravel');

        $this->assertStringContainsString('server_name app.local;', $result);
        $this->assertStringContainsString('try_files $uri $uri/ /index.php?$query_string;', $result);
    }

    public function test_render_vhost_with_custom_template(): void
    {
        $template = 'server { server_name {domain}; root {container_root}; try_files {try_files}; }';
        $vhost = new VhostService;
        $result = $vhost->renderVhost('custom.local', '/var/www/custom', 'php', $template);

        $this->assertStringContainsString('server_name custom.local;', $result);
        $this->assertStringContainsString('root /var/www/custom;', $result);
    }
}
