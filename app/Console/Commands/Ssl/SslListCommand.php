<?php

namespace App\Console\Commands\Ssl;

use App\Services\SslService;
use Illuminate\Console\Command;

class SslListCommand extends Command
{
    protected $signature = 'dstack:ssl:list';

    protected $description = 'List all SSL certificates';

    public function __construct(
        protected SslService $sslService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->info('==> SSL Certificates');

        $certs = $this->sslService->listCerts();

        if (empty($certs)) {
            $this->line('No SSL certificates found.');

            return self::SUCCESS;
        }

        $rows = [];
        foreach ($certs as $cert) {
            $rows[] = [
                'Domain' => $cert['domain'],
                'Cert Path' => $cert['cert_path'],
                'Key Path' => $cert['key_path'],
                'Exists' => $cert['exists'] ? 'Yes' : 'No',
            ];
        }

        $this->table(['Domain', 'Cert Path', 'Key Path', 'Exists'], $rows);

        return self::SUCCESS;
    }
}
