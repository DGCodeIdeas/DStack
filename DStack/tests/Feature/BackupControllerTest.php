<?php

namespace Tests\Feature;

use App\Services\BackupService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class BackupControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_create_backup_returns_success(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('backup')->willReturn([
            'success' => true,
            'backup_id' => '20260727_120000',
            'path' => '/opt/dstack-panel/backups/20260727_120000',
            'files' => ['all.sql.gz'],
            'message' => "Backup '20260727_120000' created.",
        ]);

        $this->app->instance(BackupService::class, $backup);

        $response = $this->postJson('/api/backup', [
            'database' => 'all',
            'description' => 'Test backup',
        ]);

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
            'backup_id' => '20260727_120000',
        ]);
    }

    public function test_index_returns_backup_list(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('listBackups')->willReturn([
            ['id' => '20260727_120000', 'timestamp' => '20260727_120000', 'description' => 'Test backup', 'database' => 'all', 'size_bytes' => 1024, 'files' => ['all.sql.gz']],
        ]);

        $this->app->instance(BackupService::class, $backup);

        $response = $this->getJson('/api/backups');

        $response->assertStatus(200);
        $response->assertJson([
            ['id' => '20260727_120000', 'description' => 'Test backup'],
        ]);
    }

    public function test_restore_returns_404_for_missing_backup(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('restore')->willReturn([
            'success' => false,
            'message' => 'Backup not found: nonexistent',
            'missing' => true,
        ]);

        $this->app->instance(BackupService::class, $backup);

        $response = $this->postJson('/api/restore', [
            'backup_id' => 'nonexistent',
        ]);

        $response->assertStatus(404);
        $response->assertJson([
            'success' => false,
            'missing' => true,
        ]);
    }

    public function test_restore_returns_success(): void
    {
        $backup = $this->createMock(BackupService::class);
        $backup->method('restore')->willReturn([
            'success' => true,
            'message' => "Restore from '20260727_120000' completed.",
        ]);

        $this->app->instance(BackupService::class, $backup);

        $response = $this->postJson('/api/restore', [
            'backup_id' => '20260727_120000',
        ]);

        $response->assertStatus(200);
        $response->assertJson([
            'success' => true,
        ]);
    }
}