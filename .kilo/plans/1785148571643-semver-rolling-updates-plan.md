# Semantic Versioning & Rolling Update Deployment Plan

## Context
Current state: single-instance panel served by systemd (`php artisan serve` on `127.0.0.1:5000`), frontend assets built on CI and rsynced to EC2. Deploys today do `systemctl restart`, which causes brief downtime.

## 0) Write Comprehensive .gitignore
Replace the existing `.gitignore` with the content below. It covers all current languages, tools, and runtime artifacts for this Laravel + Docker + Bun/Webpack project, while preserving the existing Docker keepers.

```gitignore
# ===== OS / Editors =====
.DS_Store
Thumbs.db
*.swp
*~
.~lock.*
*.tmp
*.bak
*.orig

# ===== IDEs & Tooling =====
/.fleet
/.idea
/.nova
/.phpactor.json
/.phpunit.cache
/.phpunit.result.cache
/.vscode
/.zed
/.claude
/.agents
/.kiro
/.kilocode
auth.json

# ===== PHP / Composer =====
/vendor
composer-setup.php
composer-setup.php.sig
/.php-cs-fixer.cache
/phpunit-result.xml

# ===== Node / Bun =====
/node_modules
bun.lockb
/.bun
/webpack.mix.cache
/package-lock.json
/yarn.lock
/pnpm-lock.yaml

# ===== Laravel =====
/.env
/.env.backup
.env.example
/auth.json
/public/build
/public/hot
/public/storage
/public/assets
/storage/*.key
/storage/pail
/storage/database/*.db
/storage/tunnel.pid
/storage/framework/views/*.php
/storage/framework/cache/*
/storage/logs/*.log
/storage/framework/sessions/*
/bootstrap/cache/*.php

# ===== Docker =====
docker/.env
docker/ssl/*
docker/vhosts/*
docker/data/*
!docker/.env.example
!docker/ssl/.gitkeep
!docker/vhosts/.gitkeep

# ===== Python =====
/venv
__pycache__/
*.py[cod]
*.pyo
*.pyd
.Python

# ===== Test / Coverage =====
/coverage
.coverage
.coverage.*
coverage.xml
htmlcov/
.phpunit.cache
.phpunit.result.cache

# ===== Archives & Builds =====
*.tar.gz
*.zip
*.7z
*.rar
dist/
build/
out/

# ===== Project-specific =====
devstack.log
/old
!old/.gitkeep
/backups
/backup-cron.log
/opt

# ===== Misc =====
*.db
*.sqlite
*.sqlite3
*.pid
*.sock
*.seed
*.pid.lock
```

## 1) Install Versioning / Release Tooling
No external SaaS. Use local tooling only:
- `git` tags as source of truth (`vMAJOR.MINOR.PATCH`).
- `php cs2cs` or a tiny custom Artisan command to sync `composer.json` `version` from the latest tag, plus an optional `public/version.json`.
- Enforce tag-driven commits in CI (`git describe --tags --exact-match` gate).

## 2) SemVer Rules
- `MAJOR`: breaking API/route/controller contract changes, auth model changes, DB schema incompatible changes.
- `MINOR`: new endpoints, new panel features, new Docker services, backwards-compatible config additions.
- `PATCH`: bug fixes, UI tweaks, auth hardening, dependency patches.
- Pre-release: `v1.2.3-beta.1` tags only for manual smoke deploys; CI treats them as non-prod.
- Tag naming: `vMAJOR.MINOR.PATCH` at repo root after merge to `main`.

## 3) Rolling Update Strategy: Blue-Green instance swap
Because the panel is a systemd app on a single EC2 host behind nginx, true "rolling" requires two live instances:

1. Create `dstack-panel@.service` slice template so `dstack-panel@green.service` and `dstack-panel@blue.service` can run simultaneously on different ports (`5000` / `5001`).
2. Add an nginx upstream `panel_backend` pointing to `127.0.0.1:5000` and `127.0.0.1:5001`.
3. Deploy step:
   - Rsync new assets + code to `/opt/dstack-panel`.
   - Start the inactive instance (green or blue), run `php artisan migrate --force`, health-check `/up` and `/api/health`.
   - Reload nginx to point upstream to the new instance first.
   - Stop the old instance gracefully (`systemctl stop` + drain).
4. Result: zero downtime, instant rollback by switching upstream back.

## 4) CI/CD Changes
Modify `.github/workflows/deploy.yml`:
- Read current active color from a file on EC2 (`/opt/dstack-panel/.active_instance`) or nginx config.
- Compute next color, rsync, start new instance, health-check, switch upstream, stop old.
- Post-deploy: verify `/` returns 200 and SSE health endpoint is reachable.
- Rollback branch: if health-check fails, keep old instance running and exit non-zero.

## 5) Validation
- Tag a `v1.2.3` on `main`, CI builds assets, deploys via blue-green, confirms zero dropped connections via nginx access logs diff.
- Run PHPUnit after deploy; fail pipeline on test failures.
