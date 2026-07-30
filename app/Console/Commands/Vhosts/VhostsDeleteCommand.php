<?php

namespace App\Console\Commands\Vhosts;

use App\Services\VhostService;
use Illuminate\Console\Command;

use function Laravel\Prompts\confirm;

class VhostsDeleteCommand extends Command
{
    protected $signature = 'dstack:vhosts:delete {domain} {--remove-files}';

    protected $description = 'Delete a virtual host';

    public function __construct(
        protected VhostService $vhostService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $domain = $this->argument('domain');
        $removeFiles = $this->option('remove-files');

        $this->info("==> Deleting virtual host: {$domain}");

        if (! $removeFiles && ! confirm("Are you sure you want to delete the virtual host '{$domain}'?")) {
            $this->line('Cancelled.');

            return self::SUCCESS;
        }

        $result = $this->vhostService->delete($domain, $removeFiles);

        if ($result['success']) {
            $this->info("Virtual host '{$domain}' deleted.");
            if (! empty($result['warnings'])) {
                foreach ($result['warnings'] as $warning) {
                    $this->warn("Warning: {$warning}");
                }
            }

            return self::SUCCESS;
        }

        $this->error($result['message'] ?? "Failed to delete virtual host '{$domain}'.");

        return self::FAILURE;
    }
}
