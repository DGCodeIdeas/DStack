<?php

namespace App\Services;

use Illuminate\Support\Facades\Config;
use Symfony\Component\Process\Process;

class RdsTunnelService
{
    protected ?string $tunnelPidFile = null;

    public function __construct()
    {
        $this->tunnelPidFile = Config::get('dstack.tunnel_pid_file');
    }

    public function connect(string $ec2Host, string $ec2User, string $ec2KeyPath, string $rdsHost, int $rdsPort = 3306, int $localPort = 3307): array
    {
        $validation = $this->validateConnectParams($ec2Host, $ec2User, $ec2KeyPath, $rdsHost, $rdsPort, $localPort);
        if ($validation !== true) {
            return ['success' => false, 'message' => $validation, 'local_port' => $localPort, 'rds_host' => $rdsHost, 'rds_port' => $rdsPort];
        }

        // Idempotent: disconnect first if already connected
        $this->disconnect();

        $keyPath = $ec2KeyPath;
        if (! str_starts_with($keyPath, '/')) {
            $keyPath = getenv('HOME').'/'.$keyPath;
        }

        $sshCmd = [
            'ssh', '-f', '-N',
            '-o', 'ExitOnForwardFailure=yes',
            '-o', 'ServerAliveInterval=30',
            '-i', $keyPath,
            '-L', "127.0.0.1:{$localPort}:{$rdsHost}:{$rdsPort}",
            "{$ec2User}@{$ec2Host}",
        ];

        $process = new Process($sshCmd);
        $process->setTimeout(30);
        $process->run();

        if ($process->getExitCode() !== 0) {
            return [
                'success' => false,
                'message' => 'SSH tunnel failed: '.trim($process->getErrorOutput() ?: $process->getOutput()),
                'local_port' => $localPort,
                'rds_host' => $rdsHost,
                'rds_port' => $rdsPort,
            ];
        }

        // Wait briefly for the forked SSH process to start, then find its PID
        usleep(300000); // 300ms

        $pgrepCmd = ['pgrep', '-f', "ssh.*127.0.0.1:{$localPort}"];
        $pgrepProcess = new Process($pgrepCmd);
        $pgrepProcess->setTimeout(5);
        $pgrepProcess->run();

        if ($pgrepProcess->getExitCode() !== 0) {
            return [
                'success' => false,
                'message' => 'Could not find tunnel PID after SSH connection',
                'local_port' => $localPort,
                'rds_host' => $rdsHost,
                'rds_port' => $rdsPort,
            ];
        }

        $pid = (int) trim($pgrepProcess->getOutput());

        $this->writePidFile($pid, $ec2Host, $ec2User, $rdsHost, $rdsPort, $localPort);

        return [
            'success' => true,
            'message' => "Tunnel established: 127.0.0.1:{$localPort} -> {$rdsHost}:{$rdsPort} via {$ec2Host}",
            'local_port' => $localPort,
            'rds_host' => $rdsHost,
            'rds_port' => $rdsPort,
        ];
    }

    public function disconnect(): array
    {
        $pidData = $this->readPidFile();

        if ($pidData === null) {
            return ['success' => true, 'message' => 'No active tunnel found'];
        }

        $pid = $pidData['pid'];

        if (posix_kill($pid, 0)) {
            posix_kill($pid, SIGTERM);
            usleep(200000); // 200ms

            if (posix_kill($pid, 0)) {
                posix_kill($pid, SIGKILL);
                usleep(100000);
            }
        }

        $this->deletePidFile();

        return ['success' => true, 'message' => 'Tunnel disconnected'];
    }

    public function getStatus(): array
    {
        $pidData = $this->readPidFile();

        if ($pidData === null) {
            return ['connected' => false, 'local_port' => null, 'rds_host' => null, 'rds_port' => null];
        }

        $pid = $pidData['pid'];

        if (! posix_kill($pid, 0)) {
            // Process is dead, clean up
            $this->deletePidFile();

            return ['connected' => false, 'local_port' => $pidData['local_port'] ?? null, 'rds_host' => $pidData['rds_host'] ?? null, 'rds_port' => $pidData['rds_port'] ?? null];
        }

        return [
            'connected' => true,
            'local_port' => $pidData['local_port'],
            'rds_host' => $pidData['rds_host'],
            'rds_port' => $pidData['rds_port'],
            'ec2_host' => $pidData['ec2_host'] ?? null,
            'ec2_user' => $pidData['ec2_user'] ?? null,
            'pid' => $pid,
        ];
    }

    protected function validateConnectParams(string $ec2Host, string $ec2User, string $ec2KeyPath, string $rdsHost, int $rdsPort, int $localPort): bool|string
    {
        foreach (['ec2_host' => $ec2Host, 'ec2_user' => $ec2User, 'rds_host' => $rdsHost] as $name => $val) {
            if (empty($val) || ! is_string($val)) {
                return "{$name} must be a non-empty string";
            }
        }

        if (empty($ec2KeyPath) || ! is_string($ec2KeyPath)) {
            return 'ec2_key_path must be a non-empty string';
        }

        if (! file_exists($ec2KeyPath)) {
            return "ec2_key_path does not exist: {$ec2KeyPath}";
        }

        if (! is_file($ec2KeyPath)) {
            return "ec2_key_path is not a file: {$ec2KeyPath}";
        }

        foreach (['rds_port' => $rdsPort, 'local_port' => $localPort] as $name => $val) {
            if (! is_int($val) || is_bool($val)) {
                return "{$name} must be an integer";
            }
            if ($val < 1 || $val > 65535) {
                return "{$name} must be between 1 and 65535, got {$val}";
            }
        }

        return true;
    }

    protected function writePidFile(int $pid, string $ec2Host, string $ec2User, string $rdsHost, int $rdsPort, int $localPort): void
    {
        $dir = dirname($this->tunnelPidFile);
        if (! is_dir($dir)) {
            mkdir($dir, 0755, true);
        }

        $data = json_encode([
            'pid' => $pid,
            'ec2_host' => $ec2Host,
            'ec2_user' => $ec2User,
            'rds_host' => $rdsHost,
            'rds_port' => $rdsPort,
            'local_port' => $localPort,
            'started_at' => date('c'),
        ], JSON_PRETTY_PRINT);

        file_put_contents($this->tunnelPidFile, $data);
    }

    protected function readPidFile(): ?array
    {
        if (! file_exists($this->tunnelPidFile)) {
            return null;
        }

        $content = file_get_contents($this->tunnelPidFile);
        if ($content === false) {
            return null;
        }

        $data = json_decode($content, true);

        return is_array($data) ? $data : null;
    }

    protected function deletePidFile(): void
    {
        if (file_exists($this->tunnelPidFile)) {
            @unlink($this->tunnelPidFile);
        }
    }
}
