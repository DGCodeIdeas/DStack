<?php

namespace Tests\Unit;

use App\Services\LogService;
use Tests\TestCase;

class LogServiceTest extends TestCase
{
    public function test_parse_logs_output_with_pipe_separated_lines(): void
    {
        $log = new LogService;
        $raw = "nginx-1 | 192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] \"GET / HTTP/1.1\" 200\n"
             ."php-1    | PHP Deprecated: something in /var/www/index.php on line 10\n"
             .'mysql-1  | 2026-07-18T19:00:01.123456Z 0 [System] [MY-010116] Server startup';

        $entries = $log->parseLogsOutput($raw);

        $this->assertCount(3, $entries);
        $this->assertEquals('nginx', $entries[0]['service']);
        $this->assertEquals('php', $entries[1]['service']);
        $this->assertEquals('mysql', $entries[2]['service']);
    }

    public function test_parse_logs_output_strips_container_index(): void
    {
        $log = new LogService;
        $raw = "nginx-1 | message here\n"
             .'redis-2 | another message';

        $entries = $log->parseLogsOutput($raw);

        $this->assertEquals('nginx', $entries[0]['service']);
        $this->assertEquals('redis', $entries[1]['service']);
    }

    public function test_parse_logs_output_with_bare_message(): void
    {
        $log = new LogService;
        $raw = 'this line has no pipe separator so it is treated as a bare message';

        $entries = $log->parseLogsOutput($raw);

        $this->assertCount(1, $entries);
        $this->assertNull($entries[0]['service']);
        $this->assertEquals('this line has no pipe separator so it is treated as a bare message', $entries[0]['message']);
    }

    public function test_parse_logs_output_with_empty_string(): void
    {
        $log = new LogService;
        $entries = $log->parseLogsOutput('');
        $this->assertEquals([], $entries);
    }

    public function test_parse_log_line_with_pipe_separator(): void
    {
        $log = new LogService;
        $line = 'nginx-1 | 192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] "GET / HTTP/1.1" 200';

        $entry = $log->parseLogLine($line);

        $this->assertEquals('nginx', $entry['service']);
        $this->assertEquals('192.168.1.1 - - [01/Jul/2026:00:00:00 +0000] "GET / HTTP/1.1" 200', $entry['message']);
        $this->assertEquals($line, $entry['raw']);
    }

    public function test_parse_log_line_without_pipe_separator(): void
    {
        $log = new LogService;
        $line = 'this line has no pipe separator';

        $entry = $log->parseLogLine($line);

        $this->assertNull($entry['service']);
        $this->assertEquals('this line has no pipe separator', $entry['message']);
    }

    public function test_parse_log_line_strips_trailing_newline(): void
    {
        $log = new LogService;
        $line = "nginx-1 | message\n";

        $entry = $log->parseLogLine($line);

        $this->assertEquals('nginx', $entry['service']);
        $this->assertEquals('message', $entry['message']);
    }

    public function test_parse_logs_output_filters_empty_lines(): void
    {
        $log = new LogService;
        $raw = "nginx-1 | message\n\n";

        $entries = $log->parseLogsOutput($raw);

        $this->assertCount(1, $entries);
    }
}
