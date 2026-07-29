<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\Artisan;
use Symfony\Component\Process\Process;

class DStackUpdate extends Command
{
    protected $signature = 'dstack:update';

    protected $description = 'Self-update: git pull, composer install, migrate, cache, blue-green restart';

    public function handle(): int
    {
        $this->info('==> DStack Panel Blue-Green Update');

        $activeColor = $this->resolveActiveColor();
        $nextColor = $activeColor === 'green' ? 'blue' : 'green';
        $nextPort = $nextColor === 'green' ? '5000' : '5001';

        $this->info("Active: $activeColor, Next: $nextColor");

        $this->info('Pulling latest code...');
        $process = new Process(['git', 'pull']);
        $process->setWorkingDirectory(base_path());
        $process->run();
        if ($process->getExitCode() !== 0) {
            $this->error('git pull failed: '.$process->getErrorOutput());

            return self::FAILURE;
        }

        $this->info('Installing PHP dependencies...');
        Artisan::call('config:clear');
        $process = new Process(['composer', 'install', 'no-dev', '--optimize-autoloader']);
        $process->setWorkingDirectory(base_path());
        $process->run();
        if ($process->getExitCode() !== 0) {
            $this->error('composer install failed: '.$process->getErrorOutput());

            return self::FAILURE;
        }

        $this->info('Running migrations...');
        Artisan::call('migrate', ['--force' => true]);

        $this->info('Caching config and routes...');
        Artisan::call('config:cache');
        Artisan::call('route:cache');

        $nextService = "dstack-panel@$nextColor.service";
        $this->info("Starting next instance: $nextService");
        $process = new Process(['systemctl', 'daemon-reload']);
        $process->run();
        $process = new Process(['systemctl', 'enable', '--now', $nextService]);
        $process->setTimeout(30);
        $process->run();
        if ($process->getExitCode() !== 0) {
            $this->warn('Could not start next instance: '.$process->getErrorOutput());
        }

        $this->info("Health-checking next instance on port $nextPort...");
        $healthy = false;
        for ($i = 0; $i < 30; $i++) {
            $health = new Process(['curl', '-fsS', "http://127.0.0.1:$nextPort/up"]);
            $health->setTimeout(5);
            $health->run();
            if ($health->isSuccessful()) {
                $healthy = true;
                break;
            }
            sleep(2);
        }

        if (! $healthy) {
            $this->error('Next instance failed health check. Rolling back...');
            $process = new Process(['systemctl', 'stop', $nextService]);
            $process->run();

            return self::FAILURE;
        }

        $this->info('Reloading nginx...');
        $process = new Process(['nginx', '-t']);
        $process->run();
        if ($process->isSuccessful()) {
            $process = new Process(['systemctl', 'reload', 'nginx']);
            $process->run();
        } else {
            $this->warn('nginx config test failed: '.$process->getErrorOutput());
        }

        $oldService = "dstack-panel@$activeColor.service";
        $this->info("Stopping old instance: $oldService");
        $process = new Process(['systemctl', 'stop', $oldService]);
        $process->run();

        $this->info("Writing active instance: $nextColor");
        file_put_contents('/opt/dstack-panel/.active_instance', $nextColor.PHP_EOL);

        $this->info('Blue-green update complete.');

        return self::SUCCESS;
    }

    private function resolveActiveColor(): string
    {
        $path = '/opt/dstack-panel/.active_instance';
        if (file_exists($path)) {
            $content = trim(file_get_contents($path));
            if ($content === 'green' || $content === 'blue') {
                return $content;
            }
        }

        return 'blue';
    }
}
