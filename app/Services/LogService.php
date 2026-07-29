<?php

namespace App\Services;

use Illuminate\Support\Facades\Config;
use Symfony\Component\Process\Exception\ProcessTimedOutException;
use Symfony\Component\Process\Process;

class LogService
{
    protected string $root;
    protected string $composeFile;
    protected string $envFile;
    protected int $timeout;
    protected array $dockerCmd;

    public function __construct()
    {
        $this->root = Config::get('dstack.root');
        $this->composeFile = Config::get('dstack.compose_file');
        $this->envFile = Config::get('dstack.env_file');
        $this->timeout = Config::get('dstack.compose_timeout');
        $this->dockerCmd = $this->detectDockerCommand();
    }

    protected function detectDockerCommand(): array
    {
        if ($this->canRun(['docker', 'compose', 'version'])) {
            return ['docker', 'compose'];
        }
        if ($this->canRun(['docker-compose', 'version'])) {
            return ['docker-compose'];
        }
        if ($this->canRun(['docker', 'version'])) {
            return ['docker', 'compose'];
        }
        return ['docker', 'compose'];
    }

    protected function canRun(array $cmd): bool
    {
        try {
            $process = new Process($cmd);
            $process->setTimeout(10);
            $process->run();
            return $process->isSuccessful();
        } catch (\Exception $e) {
            return false;
        }
    }

    protected function baseCommand(): array
    {
        return array_merge(
            $this->dockerCmd,
            ['--env-file', $this->envFile],
            ['-f', $this->composeFile]
        );
    }

    public function getLogs(string $service, int $lines = 50): array
    {
        $validTargets = ['nginx', 'php', 'mysql', 'redis', 'phpmyadmin', 'all'];

        if (!in_array($service, $validTargets)) {
            return [
                'success' => false,
                'message' => "Unknown service '{$service}'. Valid targets: " . implode(', ', $validTargets),
                'service' => $service,
                'lines' => [],
                'entries' => [],
                'raw' => '',
                'truncated' => false,
            ];
        }

        $lines = max(1, min(5000, $lines));

        $cmd = array_merge(
            $this->baseCommand(),
            ['logs', '--no-color', '--tail', (string) $lines, $service]
        );

        $result = $this->runProcess($cmd);

        if (!$result['success']) {
            return [
                'success' => false,
                'message' => $result['message'],
                'service' => $service,
                'lines' => [],
                'entries' => [],
                'raw' => $result['stdout'] ?? '',
                'truncated' => false,
            ];
        }

        $raw = $result['stdout'] ?? '';
        $entries = $this->parseLogsOutput($raw);
        $lineStrings = array_column($entries, 'raw');
        $truncated = $lines > 0 && count($lineStrings) >= $lines;

        return [
            'success' => true,
            'message' => 'OK',
            'service' => $service,
            'lines' => $lineStrings,
            'entries' => $entries,
            'raw' => $raw,
            'truncated' => $truncated,
        ];
    }

    public function parseLogsOutput(string $raw): array
    {
        if (empty($raw)) {
            return [];
        }

        return array_filter(
            array_map(function (string $line) {
                return $this->parseLogLine($line);
            }, explode("\n", $raw)),
            fn($entry) => trim($entry['raw']) !== ''
        );
    }

    public function parseLogLine(string $line): array
    {
        $line = rtrim($line, "\n");
        if (preg_match('/^(\S+)\s+\|\s?(.*)$/', $line, $m)) {
            $service = $m[1];
            // Strip container index (e.g. nginx-1 -> nginx)
            $parts = explode('-', $service);
            if (count($parts) === 2 && ctype_digit($parts[1])) {
                $service = $parts[0];
            }
            return ['raw' => $line, 'service' => $service, 'message' => $m[2]];
        }
        return ['raw' => $line, 'service' => null, 'message' => $line];
    }

    protected function runProcess(array $cmd): array
    {
        try {
            $process = new Process($cmd);
            $process->setTimeout($this->timeout);
            $process->setWorkingDirectory($this->root);
            $process->run();
        } catch (ProcessTimedOutException $e) {
            return ['success' => false, 'message' => "Command timed out after {$this->timeout}s: " . implode(' ', $cmd), 'stdout' => '', 'stderr' => ''];
        } catch (\Exception $e) {
            return ['success' => false, 'message' => "OS error running command: {$e->getMessage()}", 'stdout' => '', 'stderr' => ''];
        }

        $stdout = $process->getOutput() ?? '';
        $stderr = $process->getErrorOutput() ?? '';

        if ($process->getExitCode() !== 0) {
            $detail = trim($stderr ?: $stdout) ?: "Command failed (exit {$process->getExitCode()})";
            return ['success' => false, 'message' => $detail, 'stdout' => $stdout, 'stderr' => $stderr];
        }

        return ['success' => true, 'message' => trim($stdout) ?: 'OK', 'stdout' => $stdout, 'stderr' => $stderr];
    }
}