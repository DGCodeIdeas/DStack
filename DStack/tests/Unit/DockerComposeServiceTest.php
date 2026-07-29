<?php

namespace Tests\Unit;

use App\Services\DockerComposeService;
use PHPUnit\Framework\TestCase;

class DockerComposeServiceTest extends TestCase
{
    public function testParsePsOutputWithJsonArray(): void
    {
        $json = json_encode([
            ['Service' => 'nginx', 'Status' => 'Up 2 hours', 'State' => 'running', 'Health' => 'healthy'],
            ['Service' => 'mysql', 'Status' => 'Up 1 hour (healthy)', 'State' => 'running'],
        ]);

        $result = DockerComposeService::parsePsOutput($json);

        $this->assertArrayHasKey('nginx', $result);
        $this->assertEquals('running', $result['nginx']['state']);
        $this->assertEquals('healthy', $result['nginx']['health']);
        $this->assertArrayHasKey('mysql', $result);
        $this->assertEquals('healthy', $result['mysql']['health']);
    }

    public function testParsePsOutputWithNewlineDelimitedJson(): void
    {
        $input = '{"Service":"nginx","Status":"Up 2 hours","State":"running","Health":"healthy"}' . "\n"
               . '{"Service":"mysql","Status":"Up 1 hour","State":"running"}';

        $result = DockerComposeService::parsePsOutput($input);

        $this->assertArrayHasKey('nginx', $result);
        $this->assertArrayHasKey('mysql', $result);
    }

    public function testParsePsOutputWithEmptyString(): void
    {
        $result = DockerComposeService::parsePsOutput('');
        $this->assertEquals([], $result);
    }

    public function testParsePsOutputWithEmptyInput(): void
    {
        $result = DockerComposeService::parsePsOutput('   ');
        $this->assertEquals([], $result);
    }

    public function testParsePsTextWithTableFormat(): void
    {
        $input = "NAME                STATUS              \nnginx               Up 2 hours          \nmysql               Up 1 hour (healthy)";

        $result = DockerComposeService::parsePsText($input);

        $this->assertArrayHasKey('nginx', $result);
        $this->assertArrayHasKey('mysql', $result);
        $this->assertEquals('healthy', $result['mysql']['health']);
    }

    public function testParsePsTextWithEmptyInput(): void
    {
        $result = DockerComposeService::parsePsText('');
        $this->assertEquals([], $result);
    }

    public function testParsePsTextWithSingleLine(): void
    {
        $result = DockerComposeService::parsePsText("NAME    STATUS");
        $this->assertEquals([], $result);
    }

    public function testEntriesToStatus(): void
    {
        $entries = [
            ['Service' => 'nginx', 'Status' => 'Up 5 minutes'],
            ['Service' => 'mysql', 'Status' => 'Exited (0) 2 hours ago'],
        ];

        $result = DockerComposeService::entriesToStatus($entries);

        $this->assertEquals('running', $result['nginx']['state']);
        $this->assertEquals('exited', $result['mysql']['state']);
    }

    public function testEntriesToStatusWithHealthInStatus(): void
    {
        $entries = [
            ['Service' => 'nginx', 'Status' => 'Up 2 hours (healthy)'],
        ];

        $result = DockerComposeService::entriesToStatus($entries);

        $this->assertEquals('healthy', $result['nginx']['health']);
    }

    public function testEntriesToStatusWithContainerIndex(): void
    {
        $entries = [
            ['Name' => 'nginx-1', 'Status' => 'Up 1 hour', 'State' => 'running'],
        ];

        $result = DockerComposeService::entriesToStatus($entries);

        $this->assertArrayHasKey('nginx-1', $result);
    }
}