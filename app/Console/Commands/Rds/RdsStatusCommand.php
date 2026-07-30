<?php

namespace App\Console\Commands\Rds;

use App\Services\RdsTunnelService;
use Illuminate\Console\Command;

class RdsStatusCommand extends Command
{
    protected $signature = 'dstack:rds:status';

    protected $description = 'Check the RDS tunnel status';

    public function __construct(
        protected RdsTunnelService $tunnelService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->info('==> RDS Tunnel Status');

        $status = $this->tunnelService->getStatus();

        if (! $status['connected']) {
            $this->line('No active tunnel.');

            return self::SUCCESS;
        }

        $this->table(
            ['Field', 'Value'],
            [
                ['Connected' => 'Yes'],
                ['Local Port' => $status['local_port']],
                ['RDS Host' => $status['rds_host']],
                ['RDS Port' => $status['rds_port']],
                ['EC2 Host' => $status['ec2_host'] ?? '-'],
                ['EC2 User' => $status['ec2_user'] ?? '-'],
                ['PID' => $status['pid']],
            ]
        );

        return self::SUCCESS;
    }
}
