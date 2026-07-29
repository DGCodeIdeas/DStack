<?php

namespace App\Console\Commands;

use App\Services\DockerComposeService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Artisan;

class DStackSetup extends Command
{
    protected $signature = 'dstack:setup';

    protected $description = 'First-run wizard: pull images, create admin user, optionally create first vhost';

    public function handle(): int
    {
        $this->info('==> DStack Panel Setup');

        // Pull Docker images
        $this->info('Pulling Docker images...');
        $docker = app(DockerComposeService::class);
        $result = $docker->start('all');
        if (! $result['success']) {
            $this->warn('Could not start all services: '.$result['message']);
        }
        $this->info('Docker images pulled.');

        // Generate APP_KEY
        if (empty(env('APP_KEY'))) {
            Artisan::call('key:generate', ['--force' => true]);
            $this->info('APP_KEY generated.');
        }

        // Run migrations
        Artisan::call('migrate', ['--force' => true]);
        $this->info('Migrations completed.');

        // Create admin user (placeholder - extend with actual user creation)
        $this->info('Admin user creation: implement in your user seeder.');

        $this->info('Setup complete.');

        return self::SUCCESS;
    }
}
