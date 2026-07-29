<?php

namespace Tests\Unit;

use App\Services\DockerComposeService;
use PHPUnit\Framework\TestCase;

class DockerComposeServiceTest extends TestCase
{
    public function test_parse_ps_output_with_json_array(): void
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

    public function test_parse_ps_output_with_newline_delimited_json(): void
    {
        $input = '{"Service":"nginx","Status":"Up 2 hours","State":"running","Health":"healthy"}'."\n"
               .'{"Service":"mysql","Status":"Up 1 hour","State":"running"}';

        $result = DockerComposeService::parsePsOutput($input);

        $this->assertArrayHasKey('nginx', $result);
        $this->assertArrayHasKey('mysql', $result);
    }

    public function test_parse_ps_output_with_empty_string(): void
    {
        $result = DockerComposeService::parsePsOutput('');
        $this->assertEquals([], $result);
    }

    public function test_parse_ps_output_with_empty_input(): void
    {
        $result = DockerComposeService::parsePsOutput('   ');
        $this->assertEquals([], $result);
    }

    public function test_parse_ps_text_with_table_format(): void
    {
        $input = "NAME                STATUS              \nnginx               Up 2 hours          \nmysql               Up 1 hour (healthy)";

        $result = DockerComposeService::parsePsText($input);

        $this->assertArrayHasKey('nginx', $result);
        $this->assertArrayHasKey('mysql', $result);
        $this->assertEquals('healthy', $result['mysql']['health']);
    }

    public function test_parse_ps_text_with_empty_input(): void
    {
        $result = DockerComposeService::parsePsText('');
        $this->assertEquals([], $result);
    }

    public function test_parse_ps_text_with_single_line(): void
    {
        $result = DockerComposeService::parsePsText('NAME    STATUS');
        $this->assertEquals([], $result);
    }

    public function test_entries_to_status(): void
    {
        $entries = [
            ['Service' => 'nginx', 'Status' => 'Up 5 minutes'],
            ['Service' => 'mysql', 'Status' => 'Exited (0) 2 hours ago'],
        ];

        $result = DockerComposeService::entriesToStatus($entries);

        $this->assertEquals('running', $result['nginx']['state']);
        $this->assertEquals('exited', $result['mysql']['state']);
    }

    public function test_entries_to_status_with_health_in_status(): void
    {
        $entries = [
            ['Service' => 'nginx', 'Status' => 'Up 2 hours (healthy)'],
        ];

        $result = DockerComposeService::entriesToStatus($entries);

        $this->assertEquals('healthy', $result['nginx']['health']);
    }

    public function test_entries_to_status_with_container_index(): void
    {
        $entries = [
            ['Name' => 'nginx-1', 'Status' => 'Up 1 hour', 'State' => 'running'],
        ];

        $result = DockerComposeService::entriesToStatus($entries);

        $this->assertArrayHasKey('nginx-1', $result);
    }
}
