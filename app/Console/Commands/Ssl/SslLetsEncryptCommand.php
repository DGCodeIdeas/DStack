<?php

namespace App\Console\Commands\Ssl;

use App\Services\SslService;
use Illuminate\Console\Command;

class SslLetsEncryptCommand extends Command
{
    protected $signature = 'dstack:ssl:letsencrypt {domain} {email}';

    protected $description = 'Create an SSL certificate using Let\'s Encrypt';

    public function __construct(
        protected SslService $sslService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $domain = $this->argument('domain');
        $email = $this->argument('email');
        $this->info("==> Creating Let's Encrypt certificate for: {$domain}");

        $result = $this->sslService->createLetsEncrypt($domain, $email);

        if ($result['success']) {
            $this->info($result['message']);

            return self::SUCCESS;
        }

        $this->error($result['message']);

        return self::FAILURE;
    }
}
