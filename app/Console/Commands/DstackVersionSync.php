<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\File;
use Symfony\Component\Process\Process;

class DstackVersionSync extends Command
{
    protected $signature = 'dstack:version-sync 
                            {--publish : Also write public/version.json}';

    protected $description = 'Sync composer.json version and optional public/version.json from latest git tag';

    public function handle(): int
    {
        $tag = $this->resolveLatestTag();
        if (! $tag) {
            $this->error('No git tag found. Tag the release first (vMAJOR.MINOR.PATCH).');

            return self::FAILURE;
        }

        $version = ltrim($tag, 'v');
        if (! preg_match('/^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$/', $version)) {
            $this->error("Tag \"$tag\" does not match SemVer (vMAJOR.MINOR.PATCH[-prerelease]).");

            return self::FAILURE;
        }

        $this->updateComposerJson($version);
        $this->info("Synced version $version from tag $tag.");

        if ($this->option('publish')) {
            $this->publishPublicVersionJson($version);
        }

        return self::SUCCESS;
    }

    private function resolveLatestTag(): ?string
    {
        $process = new Process(['git', 'describe', '--tags', '--abbrev=0']);
        $process->setWorkingDirectory(base_path());
        $process->run();

        if (! $process->isSuccessful()) {
            return null;
        }

        return trim($process->getOutput());
    }

    private function updateComposerJson(string $version): void
    {
        $path = base_path('composer.json');
        $json = json_decode(File::get($path), true, 512, JSON_THROW_ON_ERROR);
        $json['version'] = $version;
        File::put($path, json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR).PHP_EOL);
    }

    private function publishPublicVersionJson(string $version): void
    {
        $dir = public_path();
        File::put($dir.'/version.json', json_encode(['version' => $version], JSON_PRETTY_PRINT).PHP_EOL);
        $this->info('Wrote public/version.json.');
    }
}
