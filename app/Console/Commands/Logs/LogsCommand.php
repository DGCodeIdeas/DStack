<?php

namespace App\Console\Commands\Logs;

use App\Services\LogService;
use Illuminate\Console\Command;
use Symfony\Component\Process\Process;

class LogsCommand extends Command
{
    protected $signature = 'dstack:logs {service} {--lines=50} {--follow}';

    protected $description = 'View service logs';

    public function __construct(
        protected LogService $logService,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $service = $this->argument('service');
        $lines = (int) $this->option('lines');
        $follow = $this->option('follow');

        if ($follow) {
            return $this->followLogs($service);
        }

        $this->info("==> Logs for {$service} (last {$lines} lines)");

        $result = $this->logService->getLogs($service, $lines);

        if (! $result['success']) {
            $this->error($result['message']);

            return self::FAILURE;
        }

        foreach ($result['lines'] as $line) {
            $this->line($line);
        }

        return self::SUCCESS;
    }

    protected function followLogs(string $service): int
    {
        $this->info("==> Following logs for {$service} (Ctrl+C to stop)");

        $root = config('dstack.root');
        $composeFile = config('dstack.compose_file');
        $envFile = config('dstack.env_file');
        $dockerCmd = $this->detectDockerCommand();

        $cmd = array_merge(
            $dockerCmd,
            ['--env-file', $envFile, '-f', $composeFile, 'logs', '--no-color', '-f', $service]
        );

        $process = new Process($cmd);
        $process->setWorkingDirectory($root);
        $process->setTty(true);
        $process->run(function (string $type, string $buffer): void {
            if ($type === Process::ERR) {
                $this->error($buffer);
            } else {
                $this->line($buffer);
            }
        });

        return $process->isSuccessful() ? self::SUCCESS : self::FAILURE;
    }

    protected function detectDockerCommand(): array
    {
        try {
            $process = new Process(['docker', 'compose', 'version']);
            $process->setTimeout(10);
            $process->run();
            if ($process->isSuccessful()) {
                return ['docker', 'compose'];
            }
        } catch (\Exception $e) {
        }

        try {
            $process = new Process(['docker-compose', 'version']);
            $process->setTimeout(10);
            $process->run();
            if ($process->isSuccessful()) {
                return ['docker-compose'];
            }
        } catch (\Exception $e) {
        }

        return ['docker', 'compose'];
    }
}
