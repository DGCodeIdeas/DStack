<?php

namespace Tests\Feature;

use App\Services\BackupService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class BackupsRestoreCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.backups_dir', '/tmp/dstack/backups');
    }

    public function test_restore_backup_exits_zero_on_success(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('getBackup')->willReturn(['id' => '20260730_120000', 'files' => ['db.sql.gz']]);
        $backup->method('restore')->willReturn(['success' => true, 'message' => "Restore from '20260730_120000' completed."]);
        $this->app->instance(BackupService::class, $backup);

        $result = $this->artisan('dstack:backups:restore', ['backup-id' => '20260730_120000'])
            ->expectsConfirmation("Are you sure you want to restore backup '20260730_120000'?", true);
        $result->assertExitCode(0);
    }
}
