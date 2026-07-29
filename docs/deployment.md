# Deployment Guide

This guide covers deploying DStack Panel to production EC2 instances using blue-green rolling updates, as well as the CI/CD pipeline configuration.

---

## Deployment Architecture

DStack Panel uses a **blue-green deployment** strategy on a single EC2 host:

```
                    ┌─────────────────────┐
                    │   nginx (host)      │
                    │  chadadigital.com   │
                    └─────────┬───────────┘
                              │ proxy_pass
                              ▼
                    ┌─────────────────────┐
                    │  panel_backend      │
                    │  upstream:          │
                    │  127.0.0.1:5000  ◄─┤── dstack-panel@green
                    │  127.0.0.1:5001  ◄─┤── dstack-panel@blue
                    └─────────────────────┘
```

- **Two systemd instances** run simultaneously on different ports (`5000`/`5001`).
- **nginx** proxies traffic to the active instance via the `panel_backend` upstream.
- Deploys switch the upstream target, achieving **zero downtime**.

---

## Prerequisites

### AWS Account

- EC2 instance running Ubuntu 22.04/24.04
- Security group allowing:
  - SSH (22) from your IP
  - HTTP (80) from `0.0.0.0/0`
  - HTTPS (443) from `0.0.0.0/0`
- Key pair for SSH access (e.g., `~/.ssh/chadadigital.pem`)

### GitHub Repository

- Push code to `DGCodeIdeas/DStack` on the `main` branch.
- Set repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `EC2_HOST` | EC2 public IP or DNS (e.g., `13.62.47.161`) |
| `EC2_USER` | SSH user (e.g., `ubuntu`) |
| `EC2_SSH_KEY` | Private SSH key contents (PEM format) |

---

## First-Time EC2 Setup

### 1. SSH into the Instance

```bash
ssh -i ~/.ssh/chadadigital.pem ubuntu@13.62.47.161
```

### 2. Run the Init Script

From your local machine:

```bash
# Copy init.sh to EC2 and execute
scp -i ~/.ssh/chadadigital.pem init.sh ubuntu@13.62.47.161:~
ssh -i ~/.ssh/chadadigital.pem ubuntu@13.62.47.161 'bash ~/init.sh'
```

Or run it directly on EC2 if the repo is already cloned:

```bash
cd /opt/dstack-panel
sudo bash init.sh
```

### 3. What init.sh Does

1. Installs Docker, PHP 8.2, Composer if missing
2. Clones or pulls the repo to `/opt/dstack-panel`
3. Installs PHP dependencies (`composer install --no-dev`)
4. Creates `.env` from `.env.example` if missing
5. Generates `APP_KEY` if not set
6. Runs database migrations
7. Installs `dstack-panel@.service` systemd template
8. Creates `.env.green` and `.env.blue` (ports 5000/5001)
9. Starts both instances: `dstack-panel@green` + `dstack-panel@blue`
10. Sets `.active_instance = green`
11. Deploys nginx vhost for `panel.chadadigital.com`
12. Reloads nginx

### 4. DNS Configuration

In your DNS provider, create an **A record**:

| Host | Type | Value |
|------|------|-------|
| `panel` | A | `13.62.47.161` |

Wait for propagation (usually seconds to a few minutes), then visit:

```
https://panel.chadadigital.com
```

### 5. Verify Deployment

```bash
# Check instances are running
sudo systemctl status dstack-panel@green dstack-panel@blue

# Check nginx vhost is loaded
sudo nginx -t
ls -l /etc/nginx/sites-enabled/panel.chadadigital.com.conf

# Health checks
curl -s http://127.0.0.1:5000/up
curl -s http://127.0.0.1:5001/up
curl -s http://127.0.0.1:5000/api/health

# Panel accessible externally
curl -s https://panel.chadadigital.com/api/health
```

---

## CI/CD Pipeline (GitHub Actions)

The pipeline in `.github/workflows/deploy.yml` performs automated blue-green deploys on every push to `main`.

### Pipeline Steps

1. **Build assets** — `bun install && bun run prod` compiles the SPA to `public/assets/`
2. **Determine active color** — Reads `/opt/dstack-panel/.active_instance` via SSH
3. **Rsync code** — Syncs the entire repo to `/opt/dstack-panel`
4. **Start next instance** — Enables and starts the inactive color (`green` or `blue`)
5. **Run migrations** — `php artisan migrate --force`
6. **Health check** — Polls `/up` and `/api/health` for up to 60 seconds
7. **Switch upstream** — `nginx -t && systemctl reload nginx`
8. **Stop old instance** — `systemctl stop dstack-panel@{old_color}`
9. **Update active file** — Writes new color to `.active_instance`

### Triggering a Deploy

```bash
# Ensure you're on main with latest changes
git checkout main
git pull

# Tag a release (triggers release.yml for assets)
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3

# Push to main triggers deploy.yml
git push origin main
```

---

## Versioning

This project follows **Semantic Versioning** (SemVer).

| Bump | When |
|------|------|
| MAJOR | Breaking API/route/auth/DB changes |
| MINOR | New endpoints, features, backwards-compatible configs |
| PATCH | Bug fixes, UI tweaks, hardening |

### Syncing Version

```bash
# After tagging v1.2.3 on main, run on the server:
php artisan dstack:version-sync --publish

# This updates composer.json "version" and writes public/version.json
```

---

## Manual Rolling Update (On-Server)

If you need to deploy manually without CI:

```bash
# SSH into EC2
ssh -i ~/.ssh/chadadigital.pem ubuntu@13.62.47.161

# Run the self-update command (handles blue-green automatically)
cd /opt/dstack-panel
sudo php artisan dstack:update
```

The command will:
1. Read current active color from `.active_instance`
2. Compute next color
3. `git pull`
4. `composer install --no-dev --optimize-autoloader`
5. `php artisan migrate --force`
6. `php artisan config:cache && php artisan route:cache`
7. Start next instance
8. Health check
9. `nginx -t && systemctl reload nginx`
10. Stop old instance
11. Write new active color

### Rollback

If the new instance fails health checks, the command automatically stops the new instance and exits with an error, leaving the old instance running. To manually rollback:

```bash
# Read current active
cat /opt/dstack-panel/.active_instance

# If current is blue and broken, switch back to green
sudo systemctl reload nginx  # nginx auto-fails over to the other upstream
# Or edit the upstream directly if needed
```

---

## Environment Files

| File | Purpose |
|------|---------|
| `.env` | Base environment (local development) |
| `.env.example` | Template for `.env` |
| `.env.green` | Green instance environment (port 5000) |
| `.env.blue` | Blue instance environment (port 5001) |

Each instance reads from its own env file via `EnvironmentFile=-/opt/dstack-panel/.env.%i` in the systemd template.

### Customizing instance envs

```bash
sudo nano /opt/dstack-panel/.env.green
sudo nano /opt/dstack-panel/.env.blue
sudo systemctl restart dstack-panel@green dstack-panel@blue
```

---

## Security Considerations

1. **SSH Access**: Restrict security group port 22 to your IP (`YOUR_IP/32`)
2. **APP_KEY**: Keep `.env.green` and `.env.blue` secure; they contain `APP_KEY`
3. **Secrets**: Use `.env` files, never commit secrets to git
4. **Firewall**: Consider `ufw` or AWS Security Groups for defense in depth
5. **HTTPS**: Configure TLS via `api/ssl/letsencrypt` for production domains
