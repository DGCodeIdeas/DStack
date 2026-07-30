<?php

namespace App\Console\Commands\Rds;

use App\Services\RdsTunnelService;
use Illuminate\Console\Command;

class RdsConnectCommand extends Command
{
    protected $signature = 'dstack:rds:connect {ec2-host} {ec2-user} {ec2-key-path} {rds-host} {--rds-port=3306} {--local-port=3307}';

    protected $description = 'Connect to an RDS instance via SSH tunnel';

    public function __construct(
        protected RdsTunnelService $tunnelService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $ec2Host = $this->argument('ec2-host');
        $ec2User = $this->argument('ec2-user');
        $ec2KeyPath = $this->argument('ec2-key-path');
        $rdsHost = $this->argument('rds-host');
        $rdsPort = (int) $this->option('rds-port');
        $localPort = (int) $this->option('local-port');

        $this->info("==> Connecting RDS tunnel: {$ec2Host} -> {$rdsHost}:{$rdsPort}");

        $result = $this->tunnelService->connect($ec2Host, $ec2User, $ec2KeyPath, $rdsHost, $rdsPort, $localPort);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
