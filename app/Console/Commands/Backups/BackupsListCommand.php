<?php

namespace App\Console\Commands\Backups;

use App\Services\BackupService;
use Illuminate\Console\Command;

class BackupsListCommand extends Command
{
    protected $signature = 'dstack:backups:list';

    protected $description = 'List all backups';

    public function __construct(
        protected BackupService $backupService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->info('==> Backups');

        $backups = $this->backupService->listBackups();

        if (empty($backups)) {
            $this->line('No backups found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($backups as $backup) {
            $rows[] = [
                'ID' => $backup['id'],
                'Timestamp' => $backup['timestamp'],
                'Database' => $backup['database'] ?? '-',
                'Description' => $backup['description'] ?? '',
                'Size' => $backup['size_bytes'] ? number_format($backup['size_bytes']).' bytes' : '-',
            ];
        }

        $this->table(['ID', 'Timestamp', 'Database', 'Description', 'Size'], $rows);

        return self::SUCCESS;
    }
}
