<?php

namespace Tests\Unit;

use App\Services\RdsTunnelService;
use Tests\TestCase;

class RdsTunnelServiceTest extends TestCase
{
    public function test_validate_connect_params_rejects_empty_ec2_host(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->connect('', 'ubuntu', '/tmp/key', 'rds.host');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('ec2_host', $result['message']);
    }

    public function test_validate_connect_params_rejects_empty_ec2_user(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->connect('1.2.3.4', '', '/tmp/key', 'rds.host');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('ec2_user', $result['message']);
    }

    public function test_validate_connect_params_rejects_empty_rds_host(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '/tmp/key', '');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('rds_host', $result['message']);
    }

    public function test_validate_connect_params_rejects_empty_key_path(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '', 'rds.host');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('ec2_key_path', $result['message']);
    }

    public function test_get_status_returns_disconnected_when_no_pid_file(): void
    {
        $tunnel = new RdsTunnelService;
        $status = $tunnel->getStatus();

        $this->assertFalse($status['connected']);
        $this->assertNull($status['local_port']);
        $this->assertNull($status['rds_host']);
    }

    public function test_disconnect_is_safe_when_no_active_tunnel(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->disconnect();

        $this->assertTrue($result['success']);
    }

    public function test_connect_rejects_bad_rds_port(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '/tmp/key', 'rds.host', 0);

        $this->assertFalse($result['success']);
    }

    public function test_connect_rejects_bad_local_port(): void
    {
        $tunnel = new RdsTunnelService;
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '/tmp/key', 'rds.host', 3306, 0);

        $this->assertFalse($result['success']);
    }
}
