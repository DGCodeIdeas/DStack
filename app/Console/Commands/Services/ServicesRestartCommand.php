<?php

namespace App\Console\Commands\Services;

use App\Services\DockerComposeService;
use Illuminate\Console\Command;

class ServicesRestartCommand extends Command
{
    protected $signature = 'dstack:services:restart {service=all}';

    protected $description = 'Restart one or all DStack services';

    public function __construct(
        protected DockerComposeService $dockerCompose,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $service = $this->argument('service');
        $this->info("==> Restarting service: {$service}");

        $result = $this->dockerCompose->restart($service);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
