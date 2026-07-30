<?php

namespace App\Console\Commands\Backups;

use App\Services\BackupService;
use Illuminate\Console\Command;

use function Laravel\Prompts\confirm;

class BackupsRestoreCommand extends Command
{
    protected $signature = 'dstack:backups:restore {backup-id} {--database=}';

    protected $description = 'Restore a backup';

    public function __construct(
        protected BackupService $backupService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $backupId = $this->argument('backup-id');
        $database = $this->option('database');

        $this->info("==> Restoring backup: {$backupId}");

        if (! confirm("Are you sure you want to restore backup '{$backupId}'?")) {
            $this->line('Cancelled.');

            return self::SUCCESS;
        }

        $result = $this->backupService->restore($backupId, $database);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
