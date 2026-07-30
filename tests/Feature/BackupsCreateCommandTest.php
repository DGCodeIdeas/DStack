<?php

namespace Tests\Feature;

use App\Services\BackupService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class BackupsCreateCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.backups_dir', '/tmp/dstack/backups');
        Config::set('dstack.compose_file', 'docker-compose.yml');
        Config::set('dstack.env_file', '.env');
    }

    public function test_create_backup_exits_zero_on_success(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('backup')->with('all', '')->willReturn([
            'success' => true,
            'backup_id' => '20260730_120000',
            'message' => "Backup '20260730_120000' created.",
        ]);
        $this->app->instance(BackupService::class, $backup);

        $result = $this->artisan('dstack:backups:create', ['--database' => 'all']);
        $result->assertExitCode(0);
    }

    public function test_create_backup_exits_one_on_failure(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('backup')->willReturn([
            'success' => false,
            'message' => 'Could not create backup directory',
        ]);
        $this->app->instance(BackupService::class, $backup);

        $result = $this->artisan('dstack:backups:create');
        $result->assertExitCode(1);
    }
}
