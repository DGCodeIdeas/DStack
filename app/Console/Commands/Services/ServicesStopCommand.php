<?php

namespace App\Console\Commands\Services;

use App\Services\DockerComposeService;
use Illuminate\Console\Command;

class ServicesStopCommand extends Command
{
    protected $signature = 'dstack:services:stop {service=all}';

    protected $description = 'Stop one or all DStack services';

    public function __construct(
        protected DockerComposeService $dockerCompose,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $service = $this->argument('service');
        $this->info("==> Stopping service: {$service}");

        $result = $this->dockerCompose->stop($service);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
