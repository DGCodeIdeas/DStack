<?php

namespace App\Services;

use Illuminate\Support\Facades\Config;
use Symfony\Component\Process\Exception\ProcessTimedOutException;
use Symfony\Component\Process\Process;

class DockerComposeService
{
    protected ?string $root = null;

    protected ?string $composeFile = null;

    protected ?string $envFile = null;

    protected int $timeout;

    protected array $dockerCmd;

    public function __construct()
    {
        $this->root = Config::get('dstack.root');
        $this->composeFile = Config::get('dstack.compose_file');
        $this->envFile = Config::get('dstack.env_file');
        $this->timeout = Config::get('dstack.compose_timeout', 60);
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

    public function run(array $cmd): array
    {
        try {
            $process = new Process($cmd);
            $process->setTimeout($this->timeout);
            $process->setWorkingDirectory($this->root);
            $process->run();
        } catch (ProcessTimedOutException $e) {
            return [
                'success' => false,
                'message' => "Command timed out after {$this->timeout}s: ".implode(' ', $cmd),
                'stdout' => '',
                'stderr' => '',
            ];
        } catch (\Exception $e) {
            return [
                'success' => false,
                'message' => "OS error running command: {$e->getMessage()}",
                'stdout' => '',
                'stderr' => '',
            ];
        }

        $stdout = $process->getOutput() ?? '';
        $stderr = $process->getErrorOutput() ?? '';

        if ($process->getExitCode() !== 0) {
            $detail = trim($stderr ?: $stdout) ?: "Command failed (exit {$process->getExitCode()})";

            return [
                'success' => false,
                'message' => $detail,
                'stdout' => $stdout,
                'stderr' => $stderr,
            ];
        }

        return [
            'success' => true,
            'message' => trim($stdout) ?: 'OK',
            'stdout' => $stdout,
            'stderr' => $stderr,
        ];
    }

    public function getAllStatus(): array
    {
        $cmd = array_merge($this->baseCommand(), ['ps', '--format', 'json']);
        $result = $this->run($cmd);

        if (! $result['success']) {
            return ['error' => $result['message']];
        }

        $parsed = $this->parsePsOutput($result['stdout']);

        if (empty($parsed) && trim($result['stdout']) !== '') {
            $parsed = $this->parsePsText($result['stdout']);
        }

        return $parsed;
    }

    public function start(string $service = 'all'): array
    {
        return $this->execute('up', $service, ['-d']);
    }

    public function stop(string $service = 'all'): array
    {
        return $this->execute('stop', $service);
    }

    public function restart(string $service = 'all'): array
    {
        return $this->execute('restart', $service);
    }

    public function stopAllExceptProtected(): array
    {
        $warnings = [];
        $known = Config::get('dstack.known_services', ['nginx', 'php', 'mysql', 'phpmyadmin', 'redis', 'all']);
        $protected = Config::get('dstack.protected_services', ['nginx']);

        foreach ($known as $service) {
            if (in_array($service, $protected)) {
                continue;
            }
            $result = $this->stop($service);
            if (! $result['success']) {
                $warnings[] = "Failed to stop {$service}: {$result['message']}";
            }
        }

        return [
            'success' => true,
            'message' => 'Stopped all non-protected services',
            'warnings' => $warnings,
        ];
    }

    protected function execute(string $composeAction, string $service, array $extra = []): array
    {
        $knownServices = Config::get('dstack.known_services', ['nginx', 'php', 'mysql', 'phpmyadmin', 'redis', 'all']);

        if (! in_array($service, $knownServices)) {
            return [
                'success' => false,
                'message' => "Unknown service '{$service}'. Valid services: ".implode(', ', $knownServices),
            ];
        }

        $cmd = array_merge($this->baseCommand(), [$composeAction]);
        if (! empty($extra)) {
            $cmd = array_merge($cmd, $extra);
        }
        if ($service !== 'all') {
            $cmd[] = $service;
        }

        return $this->run($cmd);
    }

    public static function parsePsOutput(string $raw): array
    {
        $raw = trim($raw);
        if ($raw === '') {
            return [];
        }

        $entries = [];
        try {
            $data = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
            $entries = is_array($data) ? $data : [$data];
        } catch (\JsonException $e) {
            foreach (explode("\n", $raw) as $line) {
                $line = trim($line);
                if ($line === '') {
                    continue;
                }
                try {
                    $entries[] = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
                } catch (\JsonException $e) {
                    continue;
                }
            }
        }

        return self::entriesToStatus($entries);
    }

    public static function parsePsText(string $raw): array
    {
        $lines = array_values(array_filter(explode("\n", trim($raw)), fn ($l) => trim($l) !== ''));
        if (count($lines) < 2) {
            return [];
        }

        preg_match('/^(\S+).*?\s{2,}(.+)$/', trim($lines[0]), $headerMatches);
        if (! isset($headerMatches[1], $headerMatches[2])) {
            return [];
        }

        $entries = [];
        for ($i = 1; $i < count($lines); $i++) {
            $line = trim($lines[$i]);
            if ($line === '') {
                continue;
            }

            if (preg_match('/^(\S+).*?\s{2,}(.+)$/', $line, $m)) {
                $entries[] = ['Service' => $m[1], 'Status' => $m[2]];
            }
        }

        return self::entriesToStatus($entries);
    }

    public static function entriesToStatus(array $entries): array
    {
        $status = [];
        foreach ($entries as $entry) {
            if (! is_array($entry)) {
                continue;
            }
            $name = $entry['Service'] ?? $entry['Name'] ?? null;
            if ($name === null) {
                continue;
            }
            $rawStatus = trim($entry['Status'] ?? '');
            $state = $entry['State'] ?? null;

            if ($state === null && $rawStatus !== '') {
                $lowered = strtolower($rawStatus);
                if (str_starts_with($lowered, 'up')) {
                    $state = 'running';
                } elseif (str_starts_with($lowered, 'exited')) {
                    $state = 'exited';
                } elseif (str_starts_with($lowered, 'paused')) {
                    $state = 'paused';
                } elseif (str_starts_with($lowered, 'restarting')) {
                    $state = 'restarting';
                } else {
                    $state = 'unknown';
                }
            }

            $health = $entry['Health'] ?? null;
            if ($health === null && str_contains($rawStatus, '(') && str_contains($rawStatus, ')')) {
                $health = substr(
                    $rawStatus,
                    strrpos($rawStatus, '(') + 1,
                    strrpos($rawStatus, ')') - strrpos($rawStatus, '(') - 1
                );
            }

            $status[$name] = [
                'status' => $rawStatus ?: null,
                'state' => $state ?: null,
                'health' => $health ?: null,
            ];
        }

        return $status;
    }
}
