<?php

namespace Tests\Unit;

use App\Services\VhostService;
use PHPUnit\Framework\TestCase;

class VhostServiceTest extends TestCase
{
    public function testValidateDomainValid(): void
    {
        [$ok, $err] = VhostService::validateDomain('example.local');
        $this->assertTrue($ok);
        $this->assertEquals('', $err);
    }

    public function testValidateDomainWithSubdomain(): void
    {
        [$ok, $err] = VhostService::validateDomain('api.example.com');
        $this->assertTrue($ok);
    }

    public function testValidateDomainEmpty(): void
    {
        [$ok, $err] = VhostService::validateDomain('');
        $this->assertFalse($ok);
    }

    public function testValidateDomainWithPathSeparator(): void
    {
        [$ok, $err] = VhostService::validateDomain('example.com/path');
        $this->assertFalse($ok);
    }

    public function testValidateDomainWithDotDot(): void
    {
        [$ok, $err] = VhostService::validateDomain('example..local');
        $this->assertFalse($ok);
    }

    public function testValidateDomainWithTrailingHyphen(): void
    {
        [$ok, $err] = VhostService::validateDomain('-example.local');
        $this->assertFalse($ok);
    }

    public function testValidateDomainWithTrailingHyphenInLabel(): void
    {
        [$ok, $err] = VhostService::validateDomain('example-.local');
        $this->assertFalse($ok);
    }

    public function testRenderVhostPhp(): void
    {
        $result = VhostService::renderVhost('test.local', '/var/www/projects/test.local', 'php');

        $this->assertStringContainsString('server_name test.local;', $result);
        $this->assertStringContainsString('root /var/www/projects/test.local;', $result);
        $this->assertStringContainsString('try_files $uri $uri/ =404;', $result);
    }

    public function testRenderVhostLaravel(): void
    {
        $result = VhostService::renderVhost('app.local', '/var/www/projects/app.local/public', 'laravel');

        $this->assertStringContainsString('server_name app.local;', $result);
        $this->assertStringContainsString('try_files $uri $uri/ /index.php?$query_string;', $result);
    }

    public function testRenderVhostWithCustomTemplate(): void
    {
        $template = 'server { server_name {domain}; root {container_root}; try_files {try_files}; }';
        $result = VhostService::renderVhost('custom.local', '/var/www/custom', 'php', $template);

        $this->assertStringContainsString('server_name custom.local;', $result);
        $this->assertStringContainsString('root /var/www/custom;', $result);
    }
}