<?php

namespace App\Services;

use Illuminate\Support\Facades\Config;
use Symfony\Component\Process\Exception\ProcessTimedOutException;
use Symfony\Component\Process\Process;

class SslService
{
    protected string $root;
    protected string $sslDir;
    protected string $vhostsDir;
    protected string $nginxContainer;
    protected int $timeout;

    public function __construct()
    {
        $this->root = Config::get('dstack.root');
        $this->sslDir = Config::get('dstack.ssl_dir');
        $this->vhostsDir = Config::get('dstack.vhosts_dir');
        $this->nginxContainer = Config::get('dstack.nginx_container');
        $this->timeout = Config::get('dstack.ssl_timeout');
    }

    public function createMkcert(string $domain): array
    {
        [$ok, $err] = VhostService::validateDomain($domain);
        if (!$ok) {
            return ['success' => false, 'domain' => $domain, 'message' => $err];
        }

        if (!self::commandExists('mkcert')) {
            return [
                'success' => false,
                'domain' => $domain,
                'message' => "mkcert not installed. Install via 'brew install mkcert' / 'sudo apt install mkcert' then run 'mkcert -install'",
            ];
        }

        $certPath = $this->sslDir . '/' . $domain . '.pem';
        $keyPath = $this->sslDir . '/' . $domain . '-key.pem';

        $cmd = ['mkcert', '-cert-file', $certPath, '-key-file', $keyPath, $domain, 'localhost', '127.0.0.1'];
        $result = $this->runProcess($cmd);

        if (!$result['success']) {
            return [
                'success' => false,
                'domain' => $domain,
                'cert_path' => $certPath,
                'key_path' => $keyPath,
                'message' => "mkcert failed: {$result['message']}",
            ];
        }

        $enable = $this->enableVhostSsl($domain);
        $warnings = $enable['warnings'] ?? [];

        return [
            'success' => true,
            'domain' => $domain,
            'cert_path' => $certPath,
            'key_path' => $keyPath,
            'message' => "Certificate created for {$domain} via mkcert",
            'vhost_enabled' => $enable['success'] ?? false,
            'warnings' => $warnings,
        ];
    }

    public function createLetsEncrypt(string $domain, string $email, string $mode = 'standalone', ?string $webrootPath = null): array
    {
        [$ok, $err] = VhostService::validateDomain($domain);
        if (!$ok) {
            return ['success' => false, 'domain' => $domain, 'message' => $err];
        }

        if (empty($email) || !str_contains($email, '@')) {
            return ['success' => false, 'domain' => $domain, 'message' => "A valid 'email' is required for Let's Encrypt registration"];
        }

        if (!self::commandExists('certbot')) {
            return [
                'success' => false,
                'domain' => $domain,
                'message' => "certbot not installed. Install via 'sudo apt install certbot' then retry.",
            ];
        }

        if ($mode === 'webroot') {
            if (empty($webrootPath)) {
                return ['success' => false, 'domain' => $domain, 'message' => "webroot mode requires 'webroot_path'"];
            }
            $cmd = ['certbot', 'certonly', '--webroot', '-w', $webrootPath, '-d', $domain, '-m', $email, '--agree-tos', '--non-interactive'];
        } else {
            $cmd = ['certbot', 'certonly', '--standalone', '-d', $domain, '-m', $email, '--agree-tos', '--non-interactive'];
        }

        $result = $this->runProcess($cmd);
        if (!$result['success']) {
            return ['success' => false, 'domain' => $domain, 'message' => "certbot failed: {$result['message']}"];
        }

        $liveDir = '/etc/letsencrypt/live/' . $domain;
        $srcCert = $liveDir . '/fullchain.pem';
        $srcKey = $liveDir . '/privkey.pem';
        $certPath = $this->sslDir . '/' . $domain . '.pem';
        $keyPath = $this->sslDir . '/' . $domain . '-key.pem';

        if (!@copy($srcCert, $certPath) || !@copy($srcKey, $keyPath)) {
            return [
                'success' => false,
                'domain' => $domain,
                'cert_path' => $certPath,
                'key_path' => $keyPath,
                'message' => "certbot issued the cert but copying from {$liveDir} failed. Run with privileges so /etc/letsencrypt is readable.",
            ];
        }

        $enable = $this->enableVhostSsl($domain);
        $warnings = $enable['warnings'] ?? [];

        return [
            'success' => true,
            'domain' => $domain,
            'cert_path' => $certPath,
            'key_path' => $keyPath,
            'message' => "Certificate created for {$domain} via Let's Encrypt",
            'vhost_enabled' => $enable['success'] ?? false,
            'warnings' => $warnings,
        ];
    }

    public function enableVhostSsl(string $domain, bool $redirectHttp = true): array
    {
        [$ok, $err] = VhostService::validateDomain($domain);
        if (!$ok) {
            return ['success' => false, 'domain' => $domain, 'message' => $err];
        }

        $configPath = $this->vhostsDir . '/' . $domain . '.conf';
        if (!file_exists($configPath)) {
            return ['success' => false, 'domain' => $domain, 'config_path' => $configPath, 'message' => "No vhost config found at {$configPath}"];
        }

        $content = file_get_contents($configPath);
        if ($content === false) {
            return ['success' => false, 'domain' => $domain, 'config_path' => $configPath, 'message' => "Could not read vhost config"];
        }

        $root = '/var/www/projects/' . $domain;
        $tryFiles = 'try_files $uri $uri/ =404;';

        if (preg_match('/^\s*root\s+([^;]+);/m', $content, $m)) {
            $root = trim($m[1]);
        }

        if (preg_match('/^\s*location\s+\/\s*\{/m', $content, $m)) {
            $blockStart = strpos($content, $m[0]) + strlen($m[0]);
            $close = strpos($content, '}', $blockStart);
            $inner = substr($content, $blockStart, $close - $blockStart);
            if (preg_match('/try_files\s+[^;]+;/', $inner, $tf)) {
                $tryFiles = $tf[0];
            }
        }

        $content = self::removeHttpsBlock($content);

        $httpsBlock = self::renderSslServerBlock(
            $domain,
            $this->sslDir . '/' . $domain . '.pem',
            $this->sslDir . '/' . $domain . '-key.pem',
            $root,
            $tryFiles
        );

        if (!str_ends_with($content, "\n")) {
            $content .= "\n";
        }
        $content = rtrim($content, "\n") . "\n\n" . $httpsBlock;

        if ($redirectHttp) {
            $content = self::injectHttpRedirect($content, $domain);
        }

        if (@file_put_contents($configPath, $content) === false) {
            return ['success' => false, 'domain' => $domain, 'config_path' => $configPath, 'message' => "Could not write vhost config"];
        }

        $warnings = $this->reloadNginx();

        return [
            'success' => true,
            'domain' => $domain,
            'config_path' => $configPath,
            'redirect_http' => $redirectHttp,
            'message' => "HTTPS server block enabled for {$domain}",
            'warnings' => $warnings,
        ];
    }

    public function listCerts(): array
    {
        $results = [];
        if (!is_dir($this->sslDir)) {
            return $results;
        }

        foreach (glob($this->sslDir . '/*.pem') as $cert) {
            $name = basename($cert);
            if (str_ends_with($name, '-key.pem')) {
                continue;
            }
            $domain = substr($name, 0, -strlen('.pem'));
            $key = $this->sslDir . '/' . $domain . '-key.pem';
            $results[] = [
                'domain' => $domain,
                'cert_path' => $cert,
                'key_path' => $key,
                'exists' => file_exists($cert) && file_exists($key),
            ];
        }

        return $results;
    }

    public static function renderSslServerBlock(string $domain, string $certPath, string $keyPath, string $root, string $tryFiles): string
    {
        return <<<'SSL'
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {domain};

    ssl_certificate {cert_path};
    ssl_certificate_key {key_path};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;

    root {root};
    index index.php index.html;

    location / {
        {try_files}
    }

    location ~ \.php$ {
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
SSL;
    }

    public static function removeHttpsBlock(string $content): string
    {
        $blocks = $this->extractServerBlocks($content);
        foreach (array_reverse($blocks) as [$start, $end, $block]) {
            if (preg_match('/^\s*listen\s+443/m', $block)) {
                $content = substr($content, 0, $start) . substr($content, $end);
            }
        }
        return $content;
    }

    public static function injectHttpRedirect(string $content, string $domain): string
    {
        $blocks = $this->extractServerBlocks($content);
        foreach ($blocks as [$start, $end, $block]) {
            $isHttp = preg_match('/^\s*listen\s+80\b/m', $block);
            $isHttps = preg_match('/^\s*listen\s+443/m', $block);
            if ($isHttp && !$isHttps) {
                $sn = preg_match('/server_name\s+([^;]+);/', $block, $m);
                if ($sn && str_contains($m[1], $domain)) {
                    $redirect = '        return 301 https://$host$request_uri;';
                    $newBlock = preg_replace(
                        '/(server_name\s+[^\n]+;\n)/',
                        "$1{$redirect}\n",
                        $block,
                        1
                    );
                    $content = substr($content, 0, $start) . $newBlock . substr($content, $end);
                    break;
                }
            }
        }
        return $content;
    }

    public static function extractServerBlocks(string $content): array
    {
        $blocks = [];
        $n = strlen($content);
        $i = 0;
        while (true) {
            $m = strpos($content, 'server {', $i);
            if ($m === false) {
                break;
            }
            $start = $m;
            $braceStart = $m + strlen('server {') - 1;
            $depth = 0;
            $j = $braceStart;
            while ($j < $n) {
                if ($content[$j] === '{') {
                    $depth++;
                } elseif ($content[$j] === '}') {
                    $depth--;
                    if ($depth === 0) {
                        break;
                    }
                }
                $j++;
            }
            $end = $j + 1;
            $blocks[] = [$start, $end, substr($content, $start, $end - $start)];
            $i = $end;
        }
        return $blocks;
    }

    protected function reloadNginx(): array
    {
        $warnings = [];
        try {
            $docker = new DockerComposeService();
            $cmd = array_merge(
                $docker->baseCommand(),
                ['exec', $this->nginxContainer, 'nginx', '-s', 'reload']
            );
            $result = $docker->run($cmd);
            if (!$result['success']) {
                $warnings[] = "nginx reload failed: {$result['message']}";
            }
        } catch (\Throwable $e) {
            $warnings[] = "nginx reload could not be attempted: {$e->getMessage()}";
        }
        return $warnings;
    }

    protected function runProcess(array $cmd): array
    {
        try {
            $process = new Process($cmd);
            $process->setTimeout($this->timeout);
            $process->run();
        } catch (ProcessTimedOutException $e) {
            return ['success' => false, 'message' => "Command timed out after {$this->timeout}s: " . implode(' ', $cmd)];
        } catch (\Exception $e) {
            return ['success' => false, 'message' => "OS error running command: {$e->getMessage()}"];
        }

        $stdout = $process->getOutput() ?? '';
        $stderr = $process->getErrorOutput() ?? '';

        if ($process->getExitCode() !== 0) {
            $detail = trim($stderr ?: $stdout) ?: "Command failed (exit {$process->getExitCode()})";
            return ['success' => false, 'message' => $detail, 'stdout' => $stdout, 'stderr' => $stderr];
        }

        return ['success' => true, 'message' => trim($stdout) ?: 'OK', 'stdout' => $stdout, 'stderr' => $stderr];
    }

    public static function commandExists(string $cmd): bool
    {
        $process = new Process(['which', $cmd]);
        $process->setTimeout(5);
        $process->run();
        return $process->isSuccessful();
    }
}