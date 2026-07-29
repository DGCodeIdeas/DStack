<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\File;
use Symfony\Component\Process\Process;

class DStackUpdate extends Command
{
    protected $signature = 'dstack:update';
    protected $description = 'Self-update: git pull, composer install, migrate, cache, restart panel';

    public function handle(): int
    {
        $this->info('==> DStack Panel Update');

        // Git pull
        $this->info('Pulling latest code...');
        $process = new Process(['git', 'pull']);
        $process->setWorkingDirectory(base_path());
        $process->run();
        if ($process->getExitCode() !== 0) {
            $this->error('git pull failed: ' . $process->getErrorOutput());
            return self::FAILURE;
        }

        // Composer install
        $this->info('Installing PHP dependencies...');
        Artisan::call('config:clear');
        $process = new Process(['composer', 'install', '--no-dev', '--optimize-autoloader']);
        $process->setWorkingDirectory(base_path());
        $process->run();
        if ($process->getExitCode() !== 0) {
            $this->error('composer install failed: ' . $process->getErrorOutput());
            return self::FAILURE;
        }

        // Migrations
        $this->info('Running migrations...');
        Artisan::call('migrate', ['--force' => true]);

        // Cache
        $this->info('Caching config and routes...');
        Artisan::call('config:cache');
        Artisan::call('route:cache');

        // Restart panel
        $this->info('Restarting panel service...');
        $process = new Process(['systemctl', 'restart', 'dstack-panel']);
        $process->run();
        if ($process->getExitCode() !== 0) {
            $this->warn('Could not restart dstack-panel via systemctl. You may need to restart manually.');
        }

        $this->info('Update complete.');
        return self::SUCCESS;
    }
}