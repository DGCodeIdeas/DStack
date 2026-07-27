<?php

namespace Tests\Unit;

use App\Services\BackupService;
use PHPUnit\Framework\TestCase;

class BackupServiceTest extends TestCase
{
    public function testValidateDbNameAll(): void
    {
        $this->assertTrue(BackupService::validateDbName('all'));
    }

    public function testValidateDbNameEmpty(): void
    {
        $this->assertTrue(BackupService::validateDbName(''));
    }

    public function testValidateDbNameNull(): void
    {
        $this->assertTrue(BackupService::validateDbName(null));
    }

    public function testValidateDbNameValid(): void
    {
        $this->assertTrue(BackupService::validateDbName('my_database'));
    }

    public function testValidateDbNameValidSimple(): void
    {
        $this->assertTrue(BackupService::validateDbName('app_db'));
    }

    public function testValidateDbNameInvalid(): void
    {
        $this->assertFalse(BackupService::validateDbName('my db'));
    }

    public function testValidateDbNameInvalidSpecialChars(): void
    {
        $this->assertFalse(BackupService::validateDbName('my-db'));
    }

    public function testValidateDbNameInvalidSemicolon(): void
    {
        $this->assertFalse(BackupService::validateDbName('app; DROP TABLE'));
    }
}