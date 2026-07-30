<?php

namespace App\Console\Commands\Ssl;

use App\Services\SslService;
use Illuminate\Console\Command;

class SslMkcertCommand extends Command
{
    protected $signature = 'dstack:ssl:mkcert {domain}';

    protected $description = 'Create an SSL certificate using mkcert';

    public function __construct(
        protected SslService $sslService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $domain = $this->argument('domain');
        $this->info("==> Creating mkcert certificate for: {$domain}");

        $result = $this->sslService->createMkcert($domain);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
