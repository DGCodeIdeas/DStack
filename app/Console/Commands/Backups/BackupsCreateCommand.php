<?php

namespace App\Console\Commands\Backups;

use App\Services\BackupService;
use Illuminate\Console\Command;

class BackupsCreateCommand extends Command
{
    protected $signature = 'dstack:backups:create {--database=all} {--description=}';

    protected $description = 'Create a new backup';

    public function __construct(
        protected BackupService $backupService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $database = $this->option('database');
        $description = $this->option('description');

        $this->info("==> Creating backup (database: {$database})");

        $result = $this->backupService->backup($database, $description ?? '');

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
