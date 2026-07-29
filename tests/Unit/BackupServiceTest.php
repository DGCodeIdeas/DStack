<?php

namespace Tests\Unit;

use App\Services\BackupService;
use PHPUnit\Framework\TestCase;

class BackupServiceTest extends TestCase
{
    public function test_validate_db_name_all(): void
    {
        $this->assertTrue(BackupService::validateDbName('all'));
    }

    public function test_validate_db_name_empty(): void
    {
        $this->assertTrue(BackupService::validateDbName(''));
    }

    public function test_validate_db_name_null(): void
    {
        $this->assertTrue(BackupService::validateDbName(null));
    }

    public function test_validate_db_name_valid(): void
    {
        $this->assertTrue(BackupService::validateDbName('my_database'));
    }

    public function test_validate_db_name_valid_simple(): void
    {
        $this->assertTrue(BackupService::validateDbName('app_db'));
    }

    public function test_validate_db_name_invalid(): void
    {
        $this->assertFalse(BackupService::validateDbName('my db'));
    }

    public function test_validate_db_name_invalid_special_chars(): void
    {
        $this->assertFalse(BackupService::validateDbName('my-db'));
    }

    public function test_validate_db_name_invalid_semicolon(): void
    {
        $this->assertFalse(BackupService::validateDbName('app; DROP TABLE'));
    }
}
