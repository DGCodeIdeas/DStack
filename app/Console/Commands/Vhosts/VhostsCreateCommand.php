<?php

namespace App\Console\Commands\Vhosts;

use App\Services\VhostService;
use Illuminate\Console\Command;

class VhostsCreateCommand extends Command
{
    protected $signature = 'dstack:vhosts:create {domain} {--root=} {--framework=php}';

    protected $description = 'Create a new virtual host';

    public function __construct(
        protected VhostService $vhostService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $domain = $this->argument('domain');
        $root = $this->option('root');
        $framework = $this->option('framework');

        $this->info("==> Creating virtual host: {$domain}");

        $result = $this->vhostService->create($domain, $root, $framework);

        if ($result['success']) {
            $this->info("Virtual host '{$domain}' created.");
            if (! empty($result['warnings'])) {
                foreach ($result['warnings'] as $warning) {
                    $this->warn("Warning: {$warning}");
                }
            }

            return self::SUCCESS;
        }

        $this->error($result['message'] ?? "Failed to create virtual host '{$domain}'.");

        return self::FAILURE;
    }
}
