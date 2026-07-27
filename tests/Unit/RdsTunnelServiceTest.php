<?php

namespace Tests\Unit;

use App\Services\RdsTunnelService;
use PHPUnit\Framework\TestCase;

class RdsTunnelServiceTest extends TestCase
{
    public function testValidateConnectParamsRejectsEmptyEc2Host(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->connect('', 'ubuntu', '/tmp/key', 'rds.host');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('ec2_host', $result['message']);
    }

    public function testValidateConnectParamsRejectsEmptyEc2User(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->connect('1.2.3.4', '', '/tmp/key', 'rds.host');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('ec2_user', $result['message']);
    }

    public function testValidateConnectParamsRejectsEmptyRdsHost(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '/tmp/key', '');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('rds_host', $result['message']);
    }

    public function testValidateConnectParamsRejectsEmptyKeyPath(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '', 'rds.host');

        $this->assertFalse($result['success']);
        $this->assertStringContainsString('ec2_key_path', $result['message']);
    }

    public function testGetStatusReturnsDisconnectedWhenNoPidFile(): void
    {
        $tunnel = new RdsTunnelService();
        $status = $tunnel->getStatus();

        $this->assertFalse($status['connected']);
        $this->assertNull($status['local_port']);
        $this->assertNull($status['rds_host']);
    }

    public function testDisconnectIsSafeWhenNoActiveTunnel(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->disconnect();

        $this->assertTrue($result['success']);
    }

    public function testConnectRejectsBadRdsPort(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '/tmp/key', 'rds.host', 0);

        $this->assertFalse($result['success']);
    }

    public function testConnectRejectsBadLocalPort(): void
    {
        $tunnel = new RdsTunnelService();
        $result = $tunnel->connect('1.2.3.4', 'ubuntu', '/tmp/key', 'rds.host', 3306, 0);

        $this->assertFalse($result['success']);
    }
}