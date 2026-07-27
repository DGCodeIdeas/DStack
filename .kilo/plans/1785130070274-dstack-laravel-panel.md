# DStack Laravel Panel — Implementation Plan

## Overview

Migrate the DStack management panel from Python/Flask to Laravel 12/PHP, following the implementation guide in `2026-07-26-Open PR for Fixed Code-Kimi.md`.

## Phases Completed

### Phase 1 — Project Scaffold ✅
- `composer.json` — laravel/framework ^12, laravel/tinker only
- `package.json` — Bun + laravel-mix + tailwind + sass (no Vue)
- `webpack.mix.js` — chada.digital mirror (simple Mix config)
- `.env.example` — panel-specific variables (APP_PORT=5000, DSTACK_ROOT, etc.)
- `config/dstack.php` — single source of truth for paths, timeouts, constants
- `config/database.php` — SQLite default (verified correct)
- `.gitignore` — updated with panel-specific entries (storage/database/*.db, storage/tunnel.pid, public/assets/)
- `routes/web.php` — SPA fallback route
- `routes/api.php` — all /api/* routes mapped 1:1 from Flask
- `app/Providers/AppServiceProvider.php` — registers all 6 services as singletons
- `app/Http/Controllers/` — 7 controllers (Dashboard, Health, Service, Vhost, Ssl, RdsTunnel, Log, Backup)
- `app/Http/Requests/` — 6 Form Request classes
- `app/Services/` — 6 service classes (DockerComposeService, VhostService, SslService, RdsTunnelService, LogService, BackupService)
- `app/Console/Commands/` — 4 Artisan commands (dstack:bootstrap, dstack:setup, dstack:update, dstack:health)
- `resources/views/layouts/panel.blade.php` — master layout
- `resources/views/panel/index.blade.php` — direct port of web-ui/index.html
- `resources/js/app.js` — port of web-ui/js/app.js
- `resources/sass/app.scss` — port of web-ui/css/style.css with Tailwind directives
- `systemd/dstack-panel.service` — systemd unit file
- `init.sh` — installation script replacing cloud/install-local.sh
- `.github/workflows/release.yml` — asset build + release on tag push
- `.github/workflows/deploy.yml` — EC2 deployment workflow

### Phase 2 — Database Migrations ✅
- `database/migrations/0001_01_01_000000_create_users_table.php` — standard Laravel
- `database/migrations/0001_01_01_000001_create_cache_table.php` — standard Laravel
- `database/migrations/0001_01_01_000002_create_jobs_table.php` — standard Laravel
- `database/migrations/2024_01_01_000003_create_projects_table.php` — projects table
- `database/migrations/2024_01_01_000004_create_virtual_hosts_table.php` — virtual_hosts table
- `database/migrations/2024_01_01_000005_create_settings_table.php` — settings table

### Phase 3 — Service Layer ✅
All 6 services ported from Python with identical logic:
- `DockerComposeService` — docker compose ps/start/stop/restart with JSON/text parsing
- `VhostService` — virtual host CRUD with /etc/hosts management and nginx reload
- `SslService` — mkcert and Let's Encrypt cert generation with HTTPS block injection
- `RdsTunnelService` — SSH tunnel via `ssh -L` with PID file state management
- `LogService` — docker compose logs with parsing (polling only, no SSE)
- `BackupService` — mysqldump/gzip pipeline via proc_open with manifest management

### Phase 4 — Validation & Controllers ✅
- 6 Form Request classes with validation rules
- 7 thin controllers delegating to service layer
- All return `['success' => bool, 'message' => string, ...]` contract

### Phase 5 — Frontend ✅
- Blade layout and index view ported from web-ui
- JS and SCSS ported with identical IDs and structure

### Phase 6 — DevOps ✅
- systemd service file created
- init.sh created
- GitHub Actions workflows created (release + deploy)
- Artisan commands created (bootstrap, setup, update, health)

## Remaining Work

### Phase 7 — Testing
- Unit tests for service parsing methods (parsePsOutput, parsePsText, entriesToStatus, validateDomain, renderVhost, etc.)
- Feature tests for controllers (mock services, assert response shapes)
- Test file structure mirroring Python test files

### Phase 8 — Cleanup (only after tests green and panel verified on EC2)
- `git rm -r server/ web-ui/ cli/`
- Update `cloud/` scripts — replace APP_PORT=5000 Flask references
- Update `cloud/server-setup-dstack.sh`
- Update `README.md`
- Commit: "feat: replace Flask panel with Laravel (DStack Panel v2)"

## Key Decisions

| Decision | Choice | Reason |
|---|---|---|
| Panel process | `php artisan serve` + systemd | Zero extra deps, low-traffic admin panel |
| Panel state | SQLite at `storage/database/panel.db` | No external DB for the panel itself |
| RDS tunnel state | PID file at `storage/tunnel.pid` | PHP-FPM is stateless — PID file bridges requests |
| Log streaming | Polling (no SSE) | JS already polls every 3s; simpler, no StreamedResponse |
| Asset pipeline | Mix + Bun, built on CI | No Node on server; mirrors chada.digital |
| Asset delivery | GitHub Release tarball | Clean repo, reproducible builds |
| Session/Cache | File driver | Avoids RDS round-trips; mirrors chada.digital |
| Protected services | `nginx` cannot be stopped via UI | Panel is proxied behind it |

## Constraints

1. Never delete or modify `docker/`, `projects/`, `cloud/`, `docs/`, or `backups/`
2. Never use `shell=true` / `shell_exec` with interpolated user input — always `Symfony\Component\Process\Process` with explicit argv arrays
3. Every service method returns `['success' => bool, 'message' => string, ...]`
4. All subprocess calls have explicit timeouts (compose=60, backup=600, ssl=120)
5. Side effects (nginx reload, /etc/hosts) collect into `$warnings[]` and return alongside result
6. Follow chada.digital conventions: Laravel Mix, Bun, file session/cache/queue, SQLite, `laravel/framework` + `laravel/tinker` only in require
7. No Node.js on the server — assets built in GitHub Actions, attached to releases as `panel-assets.tar.gz`
8. Panel process: `php artisan serve --host=127.0.0.1 --port=5000` wrapped in systemd, reverse-proxied behind managed nginx container
9. Delete `server/`, `web-ui/`, `cli/` only after all tests are green