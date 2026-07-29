<?php

namespace App\Services;

use Illuminate\Support\Facades\Config;
use Symfony\Component\Process\Exception\ProcessTimedOutException;
use Symfony\Component\Process\Process;

class BackupService
{
    protected string $root;
    protected string $backupsDir;
    protected string $composeFile;
    protected string $envFile;
    protected int $timeout;
    protected array $dockerCmd;
    protected string $dbRootPassword;

    public function __construct()
    {
        $this->root = Config::get('dstack.root');
        $this->backupsDir = Config::get('dstack.backups_dir');
        $this->composeFile = Config::get('dstack.compose_file');
        $this->envFile = Config::get('dstack.env_file');
        $this->timeout = Config::get('dstack.backup_timeout');
        $this->dockerCmd = $this->detectDockerCommand();
        $this->dbRootPassword = getenv('DB_ROOT_PASSWORD') ?: '';
    }

    public static function validateDbName(?string $name): bool
    {
        if ($name === null || $name === '' || $name === 'all') {
            return true;
        }
        return (bool) preg_match('/^[A-Za-z0-9_]+$/', $name);
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

    protected function composeBase(): array
    {
        return $this->baseCommand();
    }

    protected function dumpArgv(string $database): array
    {
        $cmd = $this->composeBase();
        $cmd[] = 'exec';
        $cmd[] = '-T';
        $cmd[] = 'mysql';
        $cmd[] = 'mysqldump';
        $cmd[] = '-uroot';
        $cmd[] = "-p{$this->dbRootPassword}";
        if ($database === 'all' || $database === '') {
            $cmd[] = '--all-databases';
        } else {
            $cmd[] = '--databases';
            $cmd[] = $database;
        }
        return $cmd;
    }

    protected function mysqlArgv(?string $database): array
    {
        $cmd = $this->composeBase();
        $cmd[] = 'exec';
        $cmd[] = '-T';
        $cmd[] = 'mysql';
        $cmd[] = '-uroot';
        $cmd[] = "-p{$this->dbRootPassword}";
        if ($database) {
            $cmd[] = $database;
        }
        return $cmd;
    }

    public function backup(string $database = 'all', string $description = ''): array
    {
        if (!$this->validateDbName($database)) {
            return [
                'success' => false,
                'message' => "Invalid database name: '{$database}'. Use 'all' or a name matching [A-Za-z0-9_]+.",
                'backup_id' => null,
                'path' => null,
                'files' => [],
            ];
        }

        $database = ($database === '' || $database === null) ? 'all' : $database;
        $timestamp = date('Ymd_His');
        $backupDir = $this->backupsDir . '/' . $timestamp;

        if (!@mkdir($backupDir, 0755, true) && !is_dir($backupDir)) {
            return [
                'success' => false,
                'message' => "Could not create backup directory",
                'backup_id' => $timestamp,
                'path' => $backupDir,
                'files' => [],
            ];
        }

        $fileName = "{$database}.sql.gz";
        $outFile = $backupDir . '/' . $fileName;

        $dumpArgv = $this->dumpArgv($database);
        $gzipArgv = ['gzip', '-c'];

        $result = $this->pipeline([$dumpArgv, $gzipArgv], $outFile);

        if (!$result['success']) {
            $this->safeRmdir($backupDir);
            return [
                'success' => false,
                'message' => $result['message'],
                'backup_id' => $timestamp,
                'path' => $backupDir,
                'files' => [],
            ];
        }

        $manifest = [
            'id' => $timestamp,
            'timestamp' => $timestamp,
            'description' => $description,
            'database' => $database,
            'files' => [$fileName],
            'size_bytes' => $this->dirSize($backupDir),
        ];

        $this->writeManifest($backupDir, $manifest);

        return [
            'success' => true,
            'backup_id' => $timestamp,
            'path' => $backupDir,
            'files' => [$fileName],
            'message' => "Backup '{$timestamp}' created.",
        ];
    }

    public function listBackups(): array
    {
        if (!is_dir($this->backupsDir)) {
            return [];
        }

        $results = [];
        foreach (glob($this->backupsDir . '/*/manifest.json') as $manifestPath) {
            $data = $this->readManifest($manifestPath);
            if ($data === null) {
                continue;
            }
            $results[] = [
                'id' => $data['id'] ?? null,
                'timestamp' => $data['timestamp'] ?? null,
                'description' => $data['description'] ?? '',
                'database' => $data['database'] ?? null,
                'size_bytes' => $data['size_bytes'] ?? 0,
                'files' => $data['files'] ?? [],
            ];
        }

        usort($results, fn($a, $b) => strcmp($b['timestamp'] ?? '', $a['timestamp'] ?? ''));
        return $results;
    }

    public function getBackup(string $backupId): array
    {
        $manifestPath = $this->backupsDir . '/' . $backupId . '/manifest.json';
        if (!file_exists($manifestPath)) {
            return ['success' => false, 'message' => "Backup not found: {$backupId}", 'missing' => true];
        }

        $data = $this->readManifest($manifestPath);
        if ($data === null) {
            return ['success' => false, 'message' => "Backup manifest unreadable: {$backupId}", 'missing' => true];
        }

        return $data;
    }

    public function restore(string $backupId, ?string $database = null): array
    {
        if ($database !== null && !$this->validateDbName($database)) {
            return [
                'success' => false,
                'message' => "Invalid database name: '{$database}'. Use a name matching [A-Za-z0-9_]+.",
            ];
        }

        $info = $this->getBackup($backupId);
        if (isset($info['missing']) && $info['missing']) {
            return ['success' => false, 'message' => $info['message'] ?? 'Backup not found', 'missing' => true];
        }

        $backupDir = $this->backupsDir . '/' . $backupId;
        $files = $info['files'] ?? [];

        if (empty($files)) {
            return ['success' => false, 'message' => 'Backup manifest contains no files to restore.'];
        }

        $errors = [];
        foreach ($files as $fname) {
            $sqlFile = $backupDir . '/' . $fname;
            if (!file_exists($sqlFile)) {
                $errors[] = "missing file: {$fname}";
                continue;
            }

            $stages = [$this->gunzipArgv($sqlFile), $this->mysqlArgv($database)];
            $res = $this->pipeline($stages);
            if (!$res['success']) {
                $errors[] = "{$fname}: {$res['message']}";
            }
        }

        if (!empty($errors)) {
            return ['success' => false, 'message' => implode('; ', $errors)];
        }

        return ['success' => true, 'message' => "Restore from '{$backupId}' completed.'];
    }

    protected function pipeline(array $stages, ?string $outFile = null): array
    {
        $procs = [];
        $outFh = null;

        try {
            foreach ($stages as $i => $stage) {
                $stdin = !empty($procs) ? $procs[count($procs) - 1]->stdout : null;
                $isLast = ($i === count($stages) - 1);

                if ($isLast && $outFile !== null) {
                    $outFh = fopen($outFile, 'wb');
                    $stdout = $outFh;
                } else {
                    $stdout = ['pipe', 'w'];
                }

                $proc = proc_open($stage, [
                    0 => $stdin ?? ['pipe', 'r'],
                    1 => $stdout,
                    2 => ['pipe', 'w'],
                ], $pipes);

                if (!empty($procs)) {
                    fclose($procs[count($procs) - 1]->stdout);
                }

                $procs[] = ['process' => $proc, 'stdout' => $stdout, 'stderr' => $pipes[2] ?? null];
            }

            $last = $procs[count($procs) - 1];
            $lastProc = $last['process'];
            $out = proc_close($lastProc);

            foreach (array_slice($procs, 0, -1) as $p) {
                fclose($p['stdout']);
                if ($p['stderr']) {
                    fclose($p['stderr']);
                }
            }

            if ($out !== 0) {
                return ['success' => false, 'message' => "Command failed (exit {$out})"];
            }

            return ['success' => true, 'message' => 'OK'];
        } catch (\Throwable $e) {
            return ['success' => false, 'message' => "OS error: {$e->getMessage()}"];
        } finally {
            if ($outFh !== null) {
                @fclose($outFh);
            }
            foreach ($procs as $p) {
                if (is_resource($p['process'])) {
                    @proc_close($p['process']);
                }
                if ($p['stderr'] && is_resource($p['stderr'])) {
                    @fclose($p['stderr']);
                }
            }
        }
    }

    protected function gunzipArgv(string $file): array
    {
        return ['gunzip', '-c', $file];
    }

    protected function writeManifest(string $backupDir, array $manifest): void
    {
        file_put_contents($backupDir . '/manifest.json', json_encode($manifest, JSON_PRETTY_PRINT));
    }

    protected function readManifest(string $path): ?array
    {
        $content = @file_get_contents($path);
        if ($content === false) {
            return null;
        }
        $data = json_decode($content, true);
        return is_array($data) ? $data : null;
    }

    protected function dirSize(string $dir): int
    {
        $total = 0;
        $iterator = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir));
        foreach ($iterator as $file) {
            if ($file->isFile()) {
                $total += $file->getSize();
            }
        }
        return $total;
    }

    protected function safeRmdir(string $dir): void
    {
        if (!is_dir($dir)) {
            return;
        }
        $items = new \FilesystemIterator($dir);
        foreach ($items as $item) {
            if ($item->isDir()) {
                $this->safeRmdir($item->getPathname());
            } else {
                @unlink($item->getPathname());
            }
        }
        @rmdir($dir);
    }
}