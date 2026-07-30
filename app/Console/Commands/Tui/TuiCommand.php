<?php

namespace App\Console\Commands\Tui;

use App\Services\BackupService;
use App\Services\DockerComposeService;
use App\Services\LogService;
use App\Services\RdsTunnelService;
use App\Services\SslService;
use App\Services\VhostService;
use Illuminate\Console\Command;

use function Laravel\Prompts\confirm;
use function Laravel\Prompts\error;
use function Laravel\Prompts\info;
use function Laravel\Prompts\select;
use function Laravel\Prompts\text;

class TuiCommand extends Command
{
    protected $signature = 'dstack:tui';

    protected $description = 'Interactive TUI for DStack management';

    public function __construct(
        protected DockerComposeService $dockerCompose,
        protected VhostService $vhostService,
        protected SslService $sslService,
        protected RdsTunnelService $tunnelService,
        protected LogService $logService,
        protected BackupService $backupService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $menuItems = [
            'Dashboard',
            'Vhosts',
            'SSL',
            'RDS Tunnel',
            'Logs',
            'Backups',
            'Exit',
        ];

        while (true) {
            $choice = select('DStack Management', $menuItems);

            return match ($choice) {
                'Dashboard' => $this->dashboard(),
                'Vhosts' => $this->vhostsMenu(),
                'SSL' => $this->sslMenu(),
                'RDS Tunnel' => $this->rdsMenu(),
                'Logs' => $this->logsMenu(),
                'Backups' => $this->backupsMenu(),
                'Exit' => self::SUCCESS,
                default => self::SUCCESS,
            };
        }
    }

    protected function dashboard(): int
    {
        $services = $this->dockerCompose->getAllStatus();

        if (empty($services)) {
            info('No services found.');
        } else {
            $rows = [];
            foreach ($services as $name => $info) {
                $rows[] = [
                    'Service' => $name,
                    'Status' => $info['state'] ?? $info['status'] ?? 'unknown',
                    'Health' => $info['health'] ?? '-',
                ];
            }
            $this->table(['Service', 'Status', 'Health'], $rows);
        }

        $actions = ['Start Service', 'Stop Service', 'Restart Service', 'Back'];
        $action = select('Action', $actions);

        if ($action === 'Back') {
            return self::SUCCESS;
        }

        $service = text('Service name (or "all")');

        return match ($action) {
            'Start Service' => $this->performServiceAction('start', $service),
            'Stop Service' => $this->performServiceAction('stop', $service),
            'Restart Service' => $this->performServiceAction('restart', $service),
            default => self::SUCCESS,
        };
    }

    protected function performServiceAction(string $action, string $service): int
    {
        $method = match ($action) {
            'start' => 'start',
            'stop' => 'stop',
            'restart' => 'restart',
            default => null,
        };

        if ($method === null) {
            error("Unknown action: {$action}");

            return self::FAILURE;
        }

        $result = $this->dockerCompose->{$method}($service);

        if ($result['success']) {
            info($result['message']);

            return self::SUCCESS;
        }

        error($result['message']);

        return self::FAILURE;
    }

    protected function vhostsMenu(): int
    {
        $action = select('Vhosts', ['List', 'Create', 'Delete', 'Back']);

        return match ($action) {
            'List' => $this->listVhosts(),
            'Create' => $this->createVhost(),
            'Delete' => $this->deleteVhost(),
            'Back' => self::SUCCESS,
            default => self::SUCCESS,
        };
    }

    protected function sslMenu(): int
    {
        $action = select('SSL', ['List Certificates', 'Create mkcert', 'Create Let\'s Encrypt', 'Back']);

        return match ($action) {
            'List Certificates' => $this->listCerts(),
            'Create mkcert' => $this->createMkcert(),
            'Create Let\'s Encrypt' => $this->createLetsEncrypt(),
            'Back' => self::SUCCESS,
            default => self::SUCCESS,
        };
    }

    protected function rdsMenu(): int
    {
        $action = select('RDS Tunnel', ['Status', 'Connect', 'Disconnect', 'Back']);

        return match ($action) {
            'Status' => $this->rdsStatus(),
            'Connect' => $this->rdsConnect(),
            'Disconnect' => $this->rdsDisconnect(),
            'Back' => self::SUCCESS,
            default => self::SUCCESS,
        };
    }

    protected function logsMenu(): int
    {
        $service = text('Service name (nginx, php, mysql, redis, phpmyadmin, all)');
        $lines = (int) text('Number of lines', default: '50');

        $result = $this->logService->getLogs($service, $lines);

        if (! $result['success']) {
            error($result['message']);

            return self::FAILURE;
        }

        foreach ($result['lines'] as $line) {
            $this->line($line);
        }

        return self::SUCCESS;
    }

    protected function backupsMenu(): int
    {
        $action = select('Backups', ['List', 'Create', 'Restore', 'Back']);

        return match ($action) {
            'List' => $this->listBackups(),
            'Create' => $this->createBackup(),
            'Restore' => $this->restoreBackup(),
            'Back' => self::SUCCESS,
            default => self::SUCCESS,
        };
    }

    protected function listVhosts(): int
    {
        $vhosts = $this->vhostService->listAll();

        if (empty($vhosts)) {
            info('No virtual hosts found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($vhosts as $vhost) {
            $rows[] = ['Domain' => $vhost['domain'], 'Root' => $vhost['root'] ?? '-', 'Framework' => $vhost['framework'] ?? 'php'];
        }

        $this->table(['Domain', 'Root', 'Framework'], $rows);

        return self::SUCCESS;
    }

    protected function createVhost(): int
    {
        $domain = text('Domain');
        $root = text('Web root (optional)');
        $framework = select('Framework', ['php', 'laravel'], default: 'php');

        $result = $this->vhostService->create($domain, $root ?: null, $framework);

        if ($result['success']) {
            info("Virtual host '{$domain}' created.");
        } else {
            error($result['message'] ?? "Failed to create virtual host '{$domain}'.");
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function deleteVhost(): int
    {
        $domain = text('Domain to delete');

        if (! confirm("Delete virtual host '{$domain}'?")) {
            $this->line('Cancelled.');

            return self::SUCCESS;
        }

        $result = $this->vhostService->delete($domain);

        if ($result['success']) {
            info("Virtual host '{$domain}' deleted.");
        } else {
            error($result['message'] ?? "Failed to delete virtual host '{$domain}'.");
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function listCerts(): int
    {
        $certs = $this->sslService->listCerts();

        if (empty($certs)) {
            info('No SSL certificates found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($certs as $cert) {
            $rows[] = ['Domain' => $cert['domain'], 'Cert' => $cert['cert_path'], 'Key' => $cert['key_path'], 'Exists' => $cert['exists'] ? 'Yes' : 'No'];
        }

        $this->table(['Domain', 'Cert', 'Key', 'Exists'], $rows);

        return self::SUCCESS;
    }

    protected function createMkcert(): int
    {
        $domain = text('Domain');
        $result = $this->sslService->createMkcert($domain);

        if ($result['success']) {
            info($result['message']);
        } else {
            error($result['message']);
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function createLetsEncrypt(): int
    {
        $domain = text('Domain');
        $email = text('Email');
        $result = $this->sslService->createLetsEncrypt($domain, $email);

        if ($result['success']) {
            info($result['message']);
        } else {
            error($result['message']);
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function rdsStatus(): int
    {
        $status = $this->tunnelService->getStatus();

        if (! $status['connected']) {
            info('No active tunnel.');

            return self::SUCCESS;
        }

        $this->table(
            ['Field', 'Value'],
            [
                ['Connected' => 'Yes'],
                ['Local Port' => $status['local_port']],
                ['RDS Host' => $status['rds_host']],
                ['RDS Port' => $status['rds_port']],
                ['EC2 Host' => $status['ec2_host'] ?? '-'],
                ['EC2 User' => $status['ec2_user'] ?? '-'],
                ['PID' => $status['pid']],
            ]
        );

        return self::SUCCESS;
    }

    protected function rdsConnect(): int
    {
        $ec2Host = text('EC2 Host');
        $ec2User = text('EC2 User');
        $ec2KeyPath = text('EC2 Key Path');
        $rdsHost = text('RDS Host');
        $rdsPort = (int) (text('RDS Port', default: '3306') ?: '3306');
        $localPort = (int) (text('Local Port', default: '3307') ?: '3307');

        $result = $this->tunnelService->connect($ec2Host, $ec2User, $ec2KeyPath, $rdsHost, $rdsPort, $localPort);

        if ($result['success']) {
            info($result['message']);
        } else {
            error($result['message']);
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function rdsDisconnect(): int
    {
        $result = $this->tunnelService->disconnect();
        info($result['message']);

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function listBackups(): int
    {
        $backups = $this->backupService->listBackups();

        if (empty($backups)) {
            info('No backups found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($backups as $backup) {
            $rows[] = ['ID' => $backup['id'], 'Timestamp' => $backup['timestamp'], 'Database' => $backup['database'] ?? '-', 'Description' => $backup['description'] ?? '', 'Size' => $backup['size_bytes'] ? number_format($backup['size_bytes']).' bytes' : '-'];
        }

        $this->table(['ID', 'Timestamp', 'Database', 'Description', 'Size'], $rows);

        return self::SUCCESS;
    }

    protected function createBackup(): int
    {
        $database = text('Database name (or "all")', default: 'all');
        $description = text('Description (optional)');

        $result = $this->backupService->backup($database, $description);

        if ($result['success']) {
            info($result['message']);
        } else {
            error($result['message']);
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }

    protected function restoreBackup(): int
    {
        $backupId = text('Backup ID');
        $database = text('Database name (optional, leave blank for all)');

        if (! confirm("Restore backup '{$backupId}'?")) {
            $this->line('Cancelled.');

            return self::SUCCESS;
        }

        $result = $this->backupService->restore($backupId, $database ?: null);

        if ($result['success']) {
            info($result['message']);
        } else {
            error($result['message']);
        }

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }
}
