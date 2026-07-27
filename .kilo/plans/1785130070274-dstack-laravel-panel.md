# DStack Panel — Laravel Port Implementation Plan

## Overview

Port the DStack Docker management panel from Python/Flask to Laravel 12/PHP, following the joint plan developed by Kimi and the user. The panel runs as a host-based PHP process managed by systemd, behind an nginx reverse-proxy. All Docker operations use `Symfony\Component\Process\Process` with explicit argv arrays — no Node.js on the server.

## Joint Plan Strategies & Requirements

### Architecture Decisions (locked in with user)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Panel runtime | `systemd` + `php artisan serve --host=127.0.0.1 --port=5000` | Zero extra deps, auto-restart, survives reboots |
| 2 | Panel location | Host process, behind nginx reverse-proxy | Panel never calls `docker compose down` on its own stack; `nginx -s reload` is safe from outside nginx |
| 3 | Assets | GitHub Actions builds release tarball; `init.sh` downloads it | No Node.js on server; repo stays clean of compiled assets |
| 4 | Panel DB | SQLite at `storage/database/panel.db` | Zero external DB dependency; built into PHP |
| 5 | Cache/Session | File driver | No Redis needed for the panel |
| 6 | RDS tunnel | `RdsTunnelService` included from day one | SSH tunnel with PID tracking at `storage/tunnel.pid` |
| 7 | Subprocess calls | `Symfony\Component\Process\Process` with explicit argv arrays | No `shell=true`; no `shell_exec` with interpolated user input |
| 8 | Service return contract | `['success' => bool, 'message' => string, ...]` | Consistent API response shape |
| 9 | Side effects | Collect into `$warnings[]`, return alongside result | nginx reload, /etc/hosts edits are non-fatal warnings |
| 10 | Timeouts | compose=60, backup=600, ssl=120 | Explicit timeouts on all subprocess calls |
| 11 | Protected services | `nginx` cannot be stopped via UI | Panel is proxied behind it |
| 12 | Docker control | Shell out to docker CLI via Symfony Process | No Docker PHP SDK dependency |
| 13 | Nginx vhosts | Rendered from Blade/PHP templates to `storage/docker/vhosts/` | Dynamic vhost generation |
| 14 | Artisan commands | `dstack:bootstrap`, `dstack:setup`, `dstack:update`, `dstack:health` | Clear naming, no confusion between init/install |
| 15 | Installation flow | `init.sh` for system prep + web first-run wizard | Only initialization on system; everything else via web |

### Constraints

1. Never delete or modify `docker/`, `projects/`, `cloud/`, `docs/`, or `backups/`
2. Never use `shell=true` / `shell_exec` with interpolated user input — always `Symfony\Component\Process\Process` with explicit argv arrays
3. Every service method returns `['success' => bool, 'message' => string, ...]`
4. All subprocess calls have explicit timeouts (compose=60, backup=600, ssl=120)
5. Side effects (nginx reload, /etc/hosts) collect into `$warnings[]` and return alongside result
6. Follow chada.digital conventions: file session/cache/queue, SQLite, `laravel/framework` + `laravel/tinker` only in require
7. No Node.js on the server — assets built in GitHub Actions, released as tarball, downloaded by `init.sh`
8. Panel process: `php artisan serve --host=127.0.0.1 --port=5000` wrapped in systemd, reverse-proxied behind managed nginx container
9. Delete `server/`, `web-ui/`, `cli/` only after all tests are green and panel verified on EC2

## Phases

### Phase 1 — Project Scaffold ✅
- `composer.json` — laravel/framework ^12, laravel/tinker only
- `config/dstack.php` — single source of truth for paths, timeouts, constants
- `config/database.php` — SQLite default
- `.env.example` — panel-specific variables (APP_PORT=5000, DSTACK_ROOT, etc.)
- `.gitignore` — updated with panel-specific entries
- `routes/web.php` — SPA fallback route
- `routes/api.php` — all /api/* routes mapped 1:1 from Flask
- `app/Providers/AppServiceProvider.php` — registers all services as singletons
- `app/Http/Controllers/` — 7 controllers (Dashboard, Health, Service, Vhost, Ssl, RdsTunnel, Log, Backup)
- `app/Http/Requests/` — 6 Form Request classes
- `app/Services/` — 6 service classes
- `app/Console/Commands/` — 4 Artisan commands (dstack:bootstrap, dstack:setup, dstack:update, dstack:health)
- `resources/views/layouts/panel.blade.php` — master layout
- `resources/views/panel/index.blade.php` — direct port of web-ui/index.html
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
All services ported from Python with identical logic:
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

### Phase 7 — Testing ✅
- Unit tests for service parsing methods (parsePsOutput, parsePsText, entriesToStatus, validateDomain, renderVhost, parseLogsOutput, parseLogLine, etc.)
- Feature tests for controllers (mock services, assert response shapes)
- Test file structure mirroring Python test files
- Added: LogServiceTest.php (parseLogsOutput, parseLogLine)
- Added: RdsTunnelServiceTest.php (validateConnectParams, getStatus, disconnect)
- Added: DashboardControllerTest.php, RdsTunnelControllerTest.php, HealthControllerTest.php

### Phase 8 — Cleanup ✅
- `server/`, `web-ui/`, `cli/` already removed in prior commit
- cloud/ scripts updated
- README.md updated
- Commit: "feat: replace Flask panel with Laravel (DStack Panel v2)"

## Deviations Corrected from Kilo Plan

The following deviations from the Kimi/user joint plan were identified and corrected:

1. **Frontend build tooling in repo**: The Kilo plan included `package.json`, `webpack.mix.js`, `resources/js/app.js`, and `resources/sass/app.scss` as committed source files. The joint plan specifies that assets are built on CI and released as a tarball — `init.sh` downloads the release asset. The repo should not contain frontend build tooling as a runtime dependency.
2. **Asset delivery strategy**: The Kilo plan referenced Mix + Bun for local development builds. The joint plan uses GitHub Actions to build assets, attach them to releases as `panel-assets.tar.gz`, and `init.sh` downloads the tarball on first install.
3. **RDS tunnel service gap**: The original Kimi mapping omitted `rds_tunnel.py` without replacement. The joint plan includes `RdsTunnelService` from day one with SSH tunnel + PID tracking.
4. **Command naming**: The initial Kimi plan used `dstack:init` and `dstack:install` which are confusingly similar. The joint plan uses `dstack:bootstrap` and `dstack:setup` for clarity.

## Key File Locations

| Path | Purpose |
|------|---------|
| `config/dstack.php` | Single source of truth for paths, timeouts, constants |
| `storage/database/panel.db` | SQLite panel state (outside public/, gitignored) |
| `storage/tunnel.pid` | RDS tunnel PID file |
| `storage/docker/vhosts/` | Generated nginx vhost configs |
| `systemd/dstack-panel.service` | systemd unit for panel process |
| `init.sh` | One-liner system installer |
| `.github/workflows/release.yml` | CI asset build + release |
| `.github/workflows/deploy.yml` | EC2 deployment |