# Plan: .gitignore, SemVer, and Rolling Update Strategy

## Goal
1. Harden `.gitignore` for the actual tech stack.
2. Add automated Semantic Versioning.
3. Define a zero-downtime Rolling Update deployment path from the current single-instance EC2 setup to a high-availability multi-instance target.

## Context
- Stack: Laravel 12 (PHP 8.5), Bun + webpack, Docker Compose, SQLite/Session file.
- CI: GitHub Actions. `release.yml` builds assets on tag push. `deploy.yml` rsyncs to `/opt/dstack-panel` and restarts `dstack-panel.service`.
- Current infra: 1 EC2 instance, `php artisan serve` behind systemd, no load balancer.
- Constraints: panel UI blade is locked; no Node.js on server.

---

## Task 1: Harden `.gitignore`

** deliverable:** Replace the current minimal `.gitignore` with a stack-specific one.

### Changes required in `.gitignore`
- Remove the wildcard `*.log` from the root; panel logs are under `storage/logs/` and should not all be ignored.
- Ignore `storage/framework/views/*.php` and `storage/framework/cache/*`.
- Ignore `.env` and `.env.example`, but ensure `.env.example` stays tracked (current `.gitignore` already allows tracking because it is an explicit file; just do not ignore it).
- Ignore Node/Bun artifacts: `node_modules/`, `bun.lockb`, `.bun/`, `dist/`, `build/`.
- Ignore Composer local binaries and installer blobs: add `composer-setup.php` and `/composer` (the local binary).
- Ignore IDE/tooling directories already present (`.fleet`, `.idea`, `.vscode`, `.zed`, `.claude`, `.agents`, `.kiro`, `.kilocode`).
- Ignore Docker runtime files: `docker/.env`, `docker/ssl/*`, `docker/vhosts/*`, `docker/data/*` (protect secrets and generated configs).
- Ignore Python virtualenv: `/venv`, `__pycache__/`, `*.py[cod]`.
- Ignore project-specific runtime files: `devstack.log`, `/backups`, `/backup-cron.log`, `storage/tunnel.pid`.
- Add keepers (`!.gitkeep`) where needed to preserve empty directories in Git.
- Ignore Laravel vendor and public build outputs already covered, plus `storage/*.key` and `storage/pail`.

---

## Task 2: Automated Semantic Versioning (SemVer)

### 2.1 Tooling
Add **`semantic-release`** to the project as a dev dependency and configure it with the **Conventional Commits** plugin.

### 2.2 Commit Convention
Require Conventional Commits in the repo:
- `feat:` → minor bump
- `fix:` → patch bump
- `BREAKING CHANGE:` in body or footer → major bump
- `chore:`, `docs:`, `style:`, `refactor:`, `test:`, `build:`, `ci:` → no version bump

### 2.3 Version Logic
- `semantic-release` analyzes commits since the last tag.
- If no Conventional Commit is detected, no release is created.
- Version is derived automatically: `MAJOR.MINOR.PATCH`.
- Changelog is generated from commit messages.

### 2.4 GitHub Actions Integration
Modify `.github/workflows/release.yml`:
1. Run on `push` to `main` (instead of only on tags, or keep tag-triggered release and add a separate version bump job on main).
2. Steps:
   - Checkout with `fetch-depth: 0` (full history).
   - Setup Node/Bun.
   - Install `semantic-release`.
   - Run `npx semantic-release` (or via Bun).
   - On release: build assets, create GitHub Release, upload `panel-assets.tar.gz`.

### 2.5 Tagging Strategy
- Use `v` prefix tags managed by `semantic-release`.
- Do not let developers manually version; `semantic-release` creates the tag.
- If manual tags are needed for hotfixes, document the override process.

---

## Task 3: Rolling Update Deployment Strategy

### 3.1 Current State → Target State
**Current:**
- 1 EC2 instance.
- `rsync` + `systemctl restart dstack-panel`.
- Downtime during restart (1-3 seconds).

**Target:**
- At least 2 EC2 instances behind an Application Load Balancer (ALB).
- Rolling updates with one instance at a time.
- Health checks at ALB and instance level.
- Automatic rollback on failure.
- Zero downtime for users.

### 3.2 Tooling Required
- AWS Application Load Balancer (ALB) or existing reverse proxy.
- EC2 Auto Scaling Group (ASG) with 2+ instances (minimum 2, desired 2, max 4).
- Launch Template or AMI built from a base image (Laravel runtime + Nginx/PM2/systemd).
- GitHub Actions OIDC or AWS credentials for deployment.
- `aws-cli` or GitHub Actions `aws-actions` for deployment orchestration.
- Optional: `aws-codedeploy` for blue/green or in-place rolling updates.

### 3.3 Rolling Update Procedure

#### Phase A: Single-Instance Zero-Downtime (Immediate)
Before adding load balancer complexity, improve the current single-instance deploy:

1. Pre-deploy: rsync new code to a temp directory (or directly to the app dir).
2. Run `php artisan migrate --force` and `php artisan config:cache` on the running instance.
3. Graceful restart: `systemctl reload dstack-panel` (if supported) or `kill -SIGUSR2` if using a queue worker; for `artisan serve`, use a lightweight reverse proxy check or accept brief maintenance window.
4. Health-check the `/up` endpoint before marking deploy successful.
5. If health check fails after 30 seconds, rollback by restoring the previous release directory or re-rsyncing the previous commit.

#### Phase B: Multi-Instance Rolling Update (Preferred)

1. **AMI / Image:** Bake a base AMI with PHP, Nginx/PM2, Composer, Bun, and systemd unit. Store released builds as artifacts.
2. **Deploy workflow:** GitHub Action triggers on release or main branch push.
3. **Pipeline steps:**
   - Build assets (`bun run prod`).
   - Package application code + assets into a release artifact (`tar.gz`).
   - Upload artifact to S3 or GitHub Releases.
   - Trigger AWS CodeDeploy or ASG lifecycle hook to pull the new release.
4. **Rolling update logic:**
   - Detach one instance from ALB (drain connections).
   - Deploy new version to that instance.
   - Run health checks (`/up`, `/api/health`).
   - Reattach instance to ALB.
   - Repeat for the next instance.
5. **Auto Rollback:** If health check fails, keep the old version running and abort the remaining instances.
6. **Database migrations:** Run migrations during the deployment of the first instance only, before traffic is shifted back.

### 3.4 Zero-Downtime Requirements
- ALB health check path: `/up` (Laravel health check) with a 30-second timeout.
- Instance deregistration delay: 60 seconds (allow in-flight requests to finish).
- Graceful shutdown in systemd: `ExecStop=/bin/sleep 30` or `KillSignal=SIGTERM` with `TimeoutStopSec=30`.
- Session consistency: ensure session driver is `file` or `redis` shared across instances (if using multi-instance, switch from file to database or redis session driver).

### 3.5 Rollback Plan
- GitHub Releases retain previous `panel-assets.tar.gz` assets.
- If a release fails, trigger a manual redeploy of the previous tag.
- Database rollback: use `php artisan migrate:rollback --step=1` only for non-destructive migrations; destructive migrations require a separate DB migration strategy.

---

## Order of Execution
1. `.gitignore` update (low risk, immediate).
2. SemVer automation (medium risk, requires commit convention adoption).
3. Rolling update infrastructure (high risk, requires AWS changes and testing).

---

## Validation
- `.gitignore`: run `git status --ignored` to verify no tracked secrets or build artifacts remain.
- SemVer: push a `feat:` commit and verify a new minor version is released automatically.
- Rolling update: deploy to a staging ASG with 2 instances, verify zero downtime using a load test during deployment.

---

## Risks
- Enforcing Conventional Commits may friction with existing commit history; use a one-time rebase or let `semantic-release` start from the next release.
- Multi-instance requires switching session driver from `file` to `database` or `redis` to avoid session affinity issues.
- Rolling updates on small instances can fail if health checks are too strict; tune ALB thresholds before production.
