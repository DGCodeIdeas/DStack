<?php

namespace App\Console\Commands\Services;

use App\Services\DockerComposeService;
use Illuminate\Console\Command;

class ServicesListCommand extends Command
{
    protected $signature = 'dstack:services:list';

    protected $description = 'List the status of all DStack services';

    public function __construct(
        protected DockerComposeService $dockerCompose,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->info('==> DStack Services');

        $services = $this->dockerCompose->getAllStatus();

        if (empty($services)) {
            $this->line('No services found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($services as $name => $info) {
            $rows[] = [
                'Service' => $name,
                'Status' => $info['state'] ?? $info['status'] ?? 'unknown',
                'Health' => $info['health'] ?? '-',
            ];
        }

        $this->table(['Service', 'Status', 'Health'], $rows);

        return self::SUCCESS;
    }
}
