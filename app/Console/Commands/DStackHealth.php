<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Symfony\Component\Process\Process;

class DStackHealth extends Command
{
    protected $signature = 'dstack:health';
    protected $description = 'Diagnostic health check for the DStack Panel';

    public function handle(): int
    {
        $this->info('==> DStack Panel Health Check');

        $checks = [
            'Docker socket accessible' => $this->checkDockerSocket(),
            'docker compose version' => $this->checkDockerCompose(),
            'Port 5000 listening' => $this->checkPort5000(),
            'storage/ writable' => $this->checkStorageWritable(),
            'SQLite DB readable' => $this->checkSqliteDb(),
            'Nginx container running' => $this->checkNginxContainer(),
        ];

        $allPassed = true;
        foreach ($checks as $name => $result) {
            $status = $result ? 'OK' : 'FAIL';
            $icon = $result ? '✓' : '✗';
            $this->line("  {$icon} {$name}: {$status}");
            if (!$result) {
                $allPassed = false;
            }
        }

        return $allPassed ? self::SUCCESS : self::FAILURE;
    }

    protected function checkDockerSocket(): bool
    {
        return file_exists('/var/run/docker.sock');
    }

    protected function checkDockerCompose(): bool
    {
        $process = new Process(['docker', 'compose', 'version']);
        $process->run();
        return $process->isSuccessful();
    }

    protected function checkPort5000(): bool
    {
        $process = new Process(['ss', '-tlnp']);
        $process->run();
        return str_contains($process->getOutput(), ':5000');
    }

    protected function checkStorageWritable(): bool
    {
        return is_writable(storage_path());
    }

    protected function checkSqliteDb(): bool
    {
        $dbPath = database_path('panel.db');
        if (!file_exists($dbPath)) {
            return false;
        }
        $process = new Process(['sqlite3', $dbPath, 'SELECT 1']);
        $process->run();
        return $process->isSuccessful();
    }

    protected function checkNginxContainer(): bool
    {
        $process = new Process(['docker', 'compose', 'ps', 'nginx']);
        $process->setWorkingDirectory(config('dstack.root'));
        $process->run();
        return str_contains($process->getOutput(), 'running');
    }
}