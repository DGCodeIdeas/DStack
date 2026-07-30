<?php

namespace Tests\Feature;

use App\Services\BackupService;
use Illuminate\Support\Facades\Config;
use Tests\TestCase;

class BackupsListCommandTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('dstack.root', '/tmp/dstack');
        Config::set('dstack.backups_dir', '/tmp/dstack/backups');
    }

    public function test_list_backups_outputs_table(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('listBackups')->willReturn([]);
        $this->app->instance(BackupService::class, $backup);

        $result = $this->artisan('dstack:backups:list');
        $result->assertExitCode(0);
        $result->expectsOutput('No backups found.');
    }
}
