<?php

namespace App\Services;

use Illuminate\Support\Facades\Config;
use Symfony\Component\Process\Process;

class VhostService
{
    protected ?string $root = null;

    protected ?string $vhostsDir = null;

    protected ?string $projectsHostDir = null;

    protected string $hostsFile = '/etc/hosts';

    protected ?string $nginxContainer = null;

    protected ?string $projectsContainerRoot = null;

    protected ?string $containerSslDir = null;

    public function __construct()
    {
        $this->root = Config::get('dstack.root');
        $this->vhostsDir = Config::get('dstack.vhosts_dir');
        $this->projectsHostDir = Config::get('dstack.projects_dir');
        $this->nginxContainer = Config::get('dstack.nginx_container');
        $this->projectsContainerRoot = Config::get('dstack.container_projects_root');
        $this->containerSslDir = Config::get('dstack.container_ssl_dir');
    }

    public static function validateDomain(string $domain): array
    {
        if (empty($domain) || ! is_string($domain)) {
            return [false, 'domain is required and must be a string'];
        }
        if (str_contains($domain, '/') || str_contains($domain, '\\') || str_contains($domain, '..')) {
            return [false, "domain must not contain path separators or '..'"];
        }
        if (! preg_match('/^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.[A-Za-z0-9-]{1,63})*$/', $domain)) {
            return [false, "domain must be a valid hostname (e.g. 'testapp.local' or 'api.example.com')"];
        }

        return [true, ''];
    }

    public function create(string $domain, ?string $root = null, string $framework = 'php'): array
    {
        $warnings = [];

        [$ok, $err] = self::validateDomain($domain);
        if (! $ok) {
            return ['success' => false, 'domain' => $domain, 'root' => null, 'config_path' => null, 'warnings' => [$err]];
        }

        if (! in_array($framework, ['php', 'laravel'])) {
            $framework = 'php';
        }

        $hostWebRoot = $this->resolveHostWebRoot($domain, $root, $framework);

        try {
            $hostWebRoot->mkdir(parents: true, exist_ok: true);
        } catch (\OSError $e) {
            return [
                'success' => false,
                'domain' => $domain,
                'root' => (string) $hostWebRoot,
                'config_path' => null,
                'warnings' => ["Could not create web root {$hostWebRoot}: {$e->getMessage()}"],
            ];
        }

        $indexFile = $hostWebRoot->child('index.php');
        if (! $indexFile->exists()) {
            try {
                $indexFile->write($this->starterIndexPhp($domain));
            } catch (\OSError $e) {
                $warnings[] = "Could not write starter index.php: {$e->getMessage()}";
            }
        }

        $warnings = array_merge($warnings, $this->updateHosts($domain, true));

        $containerRoot = $this->mapToContainerRoot($hostWebRoot, $warnings);

        $configPath = $this->vhostsDir."/{$domain}.conf";
        try {
            $rendered = $this->renderVhost($domain, $containerRoot, $framework);
            file_put_contents($configPath, $rendered);
        } catch (\Throwable $e) {
            return [
                'success' => false,
                'domain' => $domain,
                'root' => (string) $hostWebRoot,
                'config_path' => $configPath,
                'warnings' => ["Could not write vhost config: {$e->getMessage()}"],
            ];
        }

        $warnings = array_merge($warnings, $this->reloadNginx());

        return [
            'success' => true,
            'domain' => $domain,
            'root' => (string) $hostWebRoot,
            'config_path' => $configPath,
            'warnings' => $warnings,
        ];
    }

    public function delete(string $domain, bool $removeFiles = false): array
    {
        $warnings = [];

        [$ok, $err] = self::validateDomain($domain);
        if (! $ok) {
            return ['success' => false, 'domain' => $domain, 'missing' => false, 'warnings' => [$err]];
        }

        $configPath = $this->vhostsDir."/{$domain}.conf";
        if (! file_exists($configPath)) {
            return ['success' => false, 'domain' => $domain, 'missing' => true, 'warnings' => ["No vhost config found at {$configPath}"]];
        }

        $hostWebRoot = null;
        $content = file_get_contents($configPath);
        if ($content !== false) {
            if (preg_match('/^\s*root\s+([^;]+);/m', $content, $m)) {
                $containerRoot = trim($m[1]);
                if (str_starts_with($containerRoot, $this->projectsContainerRoot)) {
                    $rel = ltrim(substr($containerRoot, strlen($this->projectsContainerRoot)), '/');
                    $hostWebRoot = $this->projectsHostDir.'/'.$rel;
                }
            }
        }

        @unlink($configPath);

        $warnings = array_merge($warnings, $this->updateHosts($domain, false));

        if ($removeFiles && $hostWebRoot !== null && is_dir($hostWebRoot)) {
            $this->rmdirRecursive($hostWebRoot);
        }

        $warnings = array_merge($warnings, $this->reloadNginx());

        return [
            'success' => true,
            'domain' => $domain,
            'missing' => false,
            'removed_config' => $configPath,
            'removed_files' => $removeFiles ? $hostWebRoot : null,
            'warnings' => $warnings,
        ];
    }

    public function listAll(): array
    {
        $results = [];
        if (! is_dir($this->vhostsDir)) {
            return $results;
        }

        foreach (glob($this->vhostsDir.'/*.conf') as $conf) {
            $domain = pathinfo($conf, PATHINFO_FILENAME);
            $entry = ['domain' => $domain, 'config_path' => $conf, 'root' => null, 'framework' => 'php'];

            $content = @file_get_contents($conf);
            if ($content === false) {
                $results[] = $entry;

                continue;
            }

            if (preg_match('/^\s*server_name\s+([^;]+);/m', $content, $m)) {
                $name = trim(explode(' ', trim($m[1]))[0]);
                if ($name !== '' && $name !== '_') {
                    $entry['domain'] = $name;
                }
            }

            if (preg_match('/^\s*root\s+([^;]+);/m', $content, $m)) {
                $containerRoot = trim($m[1]);
                if (str_starts_with($containerRoot, $this->projectsContainerRoot)) {
                    $rel = ltrim(substr($containerRoot, strlen($this->projectsContainerRoot)), '/');
                    $entry['root'] = $this->projectsHostDir.'/'.$rel;
                } else {
                    $entry['root'] = $containerRoot;
                }
            }

            if (str_contains($content, 'index.php?$query_string')) {
                $entry['framework'] = 'laravel';
            }

            $results[] = $entry;
        }

        return $results;
    }

    protected function resolveHostWebRoot(string $domain, ?string $root, string $framework): \SplFileInfo
    {
        if ($root !== null) {
            $path = new \SplFileInfo($root);
            if (! $path->isAbsolute()) {
                $path = new \SplFileInfo($this->projectsHostDir.'/'.$root);
            }

            return $path;
        }

        if ($framework === 'laravel') {
            return new \SplFileInfo($this->projectsHostDir.'/'.$domain.'/public');
        }

        return new \SplFileInfo($this->projectsHostDir.'/'.$domain);
    }

    protected function mapToContainerRoot(string $hostWebRoot, array &$warnings = []): string
    {
        if (str_starts_with($hostWebRoot, $this->projectsHostDir)) {
            $rel = ltrim(substr($hostWebRoot, strlen($this->projectsHostDir)), '/');

            return $this->projectsContainerRoot.'/'.$rel;
        }

        $warnings[] = "Web root {$hostWebRoot} is outside {$this->projectsHostDir}; using it verbatim as the container root (may not be reachable by nginx).";

        return $hostWebRoot;
    }

    protected function updateHosts(string $domain, bool $add): array
    {
        $warnings = [];
        $entry = "127.0.0.1 {$domain}";

        if (! file_exists($this->hostsFile)) {
            $warnings[] = "Hosts file {$this->hostsFile} does not exist; skipping.";

            return $warnings;
        }

        $lines = @file($this->hostsFile, FILE_IGNORE_NEW_LINES);
        if ($lines === false) {
            $warnings[] = "Could not read {$this->hostsFile}; run with privileges to update hosts.";

            return $warnings;
        }

        $hasEntry = collect($lines)->contains(fn ($line) => str_contains($line, $entry));

        if ($add && ! $hasEntry) {
            $result = @file_put_contents($this->hostsFile, "\n{$entry}\n", FILE_APPEND);
            if ($result === false) {
                try {
                    $this->sudoShell("echo '{$entry}' >> {$this->hostsFile}");
                } catch (\Throwable $e) {
                    $warnings[] = "Could not add {$entry} to {$this->hostsFile}: {$e->getMessage()}. Add it manually or run with privileges.";
                }
            }
        } elseif (! $add && $hasEntry) {
            $newLines = array_filter($lines, fn ($line) => ! str_contains($line, $entry));
            $result = @file_put_contents($this->hostsFile, implode("\n", $newLines)."\n");
            if ($result === false) {
                try {
                    $tmp = implode("\n", array_map('rtrim', $newLines));
                    $this->sudoShell("cat > {$this->hostsFile} <<'EOF'\n{$tmp}\nEOF");
                } catch (\Throwable $e) {
                    $warnings[] = "Could not remove {$entry} from {$this->hostsFile}: {$e->getMessage()}. Remove it manually or run with privileges.";
                }
            }
        }

        return $warnings;
    }

    protected function reloadNginx(): array
    {
        $warnings = [];
        try {
            $docker = new DockerComposeService;
            $cmd = array_merge(
                $docker->baseCommand(),
                ['exec', $this->nginxContainer, 'nginx', '-s', 'reload']
            );
            $result = $docker->run($cmd);
            if (! $result['success']) {
                $warnings[] = "nginx reload failed: {$result['message']}";
            }
        } catch (\Throwable $e) {
            $warnings[] = "nginx reload could not be attempted: {$e->getMessage()}";
        }

        return $warnings;
    }

    protected function sudoShell(string $cmd): void
    {
        $process = new Process(['sudo', 'sh', '-c', $cmd]);
        $process->setTimeout(15);
        $process->run();
        if ($process->getExitCode() !== 0) {
            throw new \RuntimeException("sudo command failed: {$process->getErrorOutput()}");
        }
    }

    protected function rmdirRecursive(string $dir): void
    {
        if (! is_dir($dir)) {
            return;
        }
        $items = new \FilesystemIterator($dir);
        foreach ($items as $item) {
            if ($item->isDir()) {
                $this->rmdirRecursive($item->getPathname());
            } else {
                @unlink($item->getPathname());
            }
        }
        @rmdir($dir);
    }

    public function renderVhost(string $domain, string $containerRoot, string $framework): string
    {
        $tryFiles = $framework === 'laravel'
            ? 'try_files $uri $uri/ /index.php?$query_string;'
            : 'try_files $uri $uri/ =404;';

        $template = $this->loadTemplate();

        return str_replace(
            ['{domain}', '{container_root}', '{try_files}'],
            [$domain, $containerRoot, $tryFiles],
            $template
        );
    }

    protected function loadTemplate(): string
    {
        $fileTpl = $this->root.'/docker/nginx-vhosts.conf';
        if (file_exists($fileTpl)) {
            $content = @file_get_contents($fileTpl);
            if ($content !== false) {
                return $content;
            }
        }

        return <<<'NGINX'
# DevStack virtual host - generated by VhostService
server {
    listen 80;
    listen [::]:80;
    server_name {domain};

    root {container_root};
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
NGINX;
    }

    protected function starterIndexPhp(string $domain): string
    {
        return <<<PHP
<?php
// DevStack managed virtual host
\$domain = {$domain};
header('Content-Type: text/html; charset=utf-8');
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DevStack &middot; <?= htmlspecialchars(\$domain) ?></title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 4rem; color: #222; }
    code { background: #f4f4f4; padding: 2px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>DevStack</h1>
  <p>Virtual host <code><?= htmlspecialchars(\$domain) ?></code> is working.</p>
  <p>PHP version: <code><?= phpversion() ?></code></p>
</body>
</html>
PHP;
    }
}
