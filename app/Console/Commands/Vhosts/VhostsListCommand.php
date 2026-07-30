<?php

namespace App\Console\Commands\Vhosts;

use App\Services\VhostService;
use Illuminate\Console\Command;

class VhostsListCommand extends Command
{
    protected $signature = 'dstack:vhosts:list';

    protected $description = 'List all virtual hosts';

    public function __construct(
        protected VhostService $vhostService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->info('==> Virtual Hosts');

        $vhosts = $this->vhostService->listAll();

        if (empty($vhosts)) {
            $this->line('No virtual hosts found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($vhosts as $vhost) {
            $rows[] = [
                'Domain' => $vhost['domain'],
                'Root' => $vhost['root'] ?? '-',
                'Framework' => $vhost['framework'] ?? 'php',
            ];
        }

        $this->table(['Domain', 'Root', 'Framework'], $rows);

        return self::SUCCESS;
    }
}
