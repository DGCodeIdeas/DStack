<?php

namespace App\Console\Commands\Rds;

use App\Services\RdsTunnelService;
use Illuminate\Console\Command;

class RdsDisconnectCommand extends Command
{
    protected $signature = 'dstack:rds:disconnect';

    protected $description = 'Disconnect the RDS SSH tunnel';

    public function __construct(
        protected RdsTunnelService $tunnelService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->info('==> Disconnecting RDS tunnel');

        $result = $this->tunnelService->disconnect();

        $this->info($result['message']);

        return $result['success'] ? self::SUCCESS : self::FAILURE;
    }
}
