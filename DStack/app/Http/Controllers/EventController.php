<?php

namespace App\Http\Controllers;

use App\Services\BackupService;
use App\Services\DockerComposeService;
use App\Services\LogService;
use App\Services\RdsTunnelService;
use App\Services\SslService;
use App\Services\VhostService;
use Symfony\Component\HttpFoundation\StreamedResponse;

class EventController extends Controller
{
    public function stream(
        DockerComposeService $docker,
        VhostService $vhost,
        SslService $ssl,
        BackupService $backup,
        RdsTunnelService $tunnel,
        LogService $log
    ): StreamedResponse {
        return response()->stream(function () use ($docker, $vhost, $ssl, $backup, $tunnel, $log) {
            ignore_user_abort(true);
            if (function_exists('set_time_limit')) {
                set_time_limit(0);
            }

            $last = [
                'services' => null,
                'vhosts' => null,
                'ssl' => null,
                'backups' => null,
                'rds' => null,
                'logs' => null,
            ];
            $logTick = 0;

            while (true) {
                if (connection_aborted()) {
                    break;
                }

                $services = $docker->getAllStatus();
                if ($this->hash($services) !== $last['services']) {
                    $this->emit('services', $services);
                    $last['services'] = $this->hash($services);
                }

                $vhosts = $vhost->listAll();
                if ($this->hash($vhosts) !== $last['vhosts']) {
                    $this->emit('vhosts', $vhosts);
                    $last['vhosts'] = $this->hash($vhosts);
                }

                $certs = $ssl->listCerts();
                if ($this->hash($certs) !== $last['ssl']) {
                    $this->emit('ssl', $certs);
                    $last['ssl'] = $this->hash($certs);
                }

                $backups = $backup->listBackups();
                if ($this->hash($backups) !== $last['backups']) {
                    $this->emit('backups', $backups);
                    $last['backups'] = $this->hash($backups);
                }

                $tunnelStatus = $tunnel->getStatus();
                if ($this->hash($tunnelStatus) !== $last['rds']) {
                    $this->emit('rds', $tunnelStatus);
                    $last['rds'] = $this->hash($tunnelStatus);
                }

                $logTick++;
                if ($logTick % 5 === 0) {
                    $result = $log->getLogs('all', 50);
                    if ($this->hash($result) !== $last['logs']) {
                        $this->emit('logs', $result);
                        $last['logs'] = $this->hash($result);
                    }
                }

                usleep(2000000);
            }
        }, 200, [
            'Content-Type' => 'text/event-stream',
            'Cache-Control' => 'no-cache',
            'X-Accel-Buffering' => 'no',
        ]);
    }

    private function emit(string $event, mixed $payload): void
    {
        $line = 'event: ' . $event . "\n";
        $line .= 'data: ' . json_encode($payload) . "\n\n";

        echo $line;
        if (ob_get_level()) {
            ob_flush();
        }
        flush();
    }

    private function hash(mixed $data): ?string
    {
        return md5(json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }
}