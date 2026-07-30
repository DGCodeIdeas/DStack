<?php

namespace App\Console\Commands\Services;

use App\Services\DockerComposeService;
use Illuminate\Console\Command;

class ServicesStartCommand extends Command
{
    protected $signature = 'dstack:services:start {service=all}';

    protected $description = 'Start one or all DStack services';

    public function __construct(
        protected DockerComposeService $dockerCompose,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $service = $this->argument('service');
        $this->info("==> Starting service: {$service}");

        $result = $this->dockerCompose->start($service);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
