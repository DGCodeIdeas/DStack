<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\File;

class DStackBootstrap extends Command
{
    protected $signature = 'dstack:bootstrap';

    protected $description = 'Bootstrap the DStack Panel environment (Docker, PHP, migrations, APP_KEY)';

    public function handle(): int
    {
        $this->info('==> DStack Panel Bootstrap');

        // Check Docker
        if (! $this->commandExists('docker')) {
            $this->error('Docker is not installed. Please install Docker first.');

            return self::FAILURE;
        }
        $this->info('Docker: OK');

        // Check Docker Compose
        if (! $this->commandExists('docker compose')) {
            $this->error('Docker Compose is not installed. Please install Docker Compose plugin.');

            return self::FAILURE;
        }
        $this->info('Docker Compose: OK');

        // Check PHP extensions
        $requiredExtensions = ['pdo', 'pdo_sqlite', 'sqlite3', 'mbstring', 'xml', 'curl', 'zip', 'posix'];
        foreach ($requiredExtensions as $ext) {
            if (! extension_loaded($ext)) {
                $this->error("PHP extension {$ext} is missing.");

                return self::FAILURE;
            }
        }
        $this->info('PHP extensions: OK');

        // Ensure storage/database is writable
        $dbDir = storage_path('database');
        if (! is_dir($dbDir)) {
            File::makeDirectory($dbDir, 0755, true);
        }
        if (! is_writable($dbDir)) {
            $this->error('storage/database/ is not writable.');

            return self::FAILURE;
        }
        $this->info('Storage directory: OK');

        // Generate APP_KEY if missing
        if (empty(env('APP_KEY'))) {
            Artisan::call('key:generate', ['--force' => true]);
            $this->info('APP_KEY generated.');
        } else {
            $this->info('APP_KEY: already set');
        }

        // Run migrations
        Artisan::call('migrate', ['--force' => true]);
        $this->info('Migrations: OK');

        $this->info('Bootstrap complete.');

        return self::SUCCESS;
    }

    protected function commandExists(string $cmd): bool
    {
        $result = shell_exec("which {$cmd} 2>/dev/null");

        return $result !== null;
    }
}
