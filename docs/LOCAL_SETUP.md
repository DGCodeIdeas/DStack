> [!WARNING]
> This document describes the legacy Flask-based architecture and is no longer accurate.
> For current documentation, see the [Documentation Index](./README.md).

# Local Development Setup

This guide provides detailed step-by-step instructions for setting up DStack locally on Kubuntu (and compatible Ubuntu/Debian-based distributions).

---

## Prerequisites

| Tool | Minimum Version | Install Command (Kubuntu/Ubuntu) |
|------|-----------------|----------------------------------|
| Docker Engine | 24.0+ | `sudo apt update && sudo apt install docker.io` |
| Docker Compose | v2 (plugin) | `sudo apt install docker-compose-plugin` |
| Git | 2.30+ | `sudo apt install git` |
| Python | 3.10+ | `sudo apt install python3.10 python3.10-venv` |
| mkcert | 1.4+ | `sudo apt install mkcert libnss3-tools` |

> **Note**: On Kubuntu 24.04+, Docker Compose v2 is included with `docker-compose-plugin`. The `docker compose` command (v2) is preferred over `docker-compose` (v1).

### Verify Prerequisites

```bash
docker --version
docker compose version
git --version
python3 --version
mkcert -version
```

All commands should output version information without errors.

---

## Quick Start (Automated)

The easiest way to get started is the one-command installer:

```bash
git clone https://github.com/dgi-dev/DStack.git
cd DStack
./cloud/install-local.sh
```

### What the Installer Does

| Step | Description |
|------|-------------|
| 1. Preflight | Checks Docker, Docker Compose, Git, Python ≥3.10, mkcert |
| 2. Clone/Update | Clones repo to `~/devstack-manager` (or `DSTACK_DIR`) if not already inside repo |
| 3. Environment | Creates `.env` from `.env.example` (prompts to edit passwords) |
| 4. Build | `docker compose -f docker/docker-compose.yml build` |
| 5. Start | `docker compose -f docker/docker-compose.yml up -d` |
| 6. Health Wait | Waits up to 120s for all containers to report healthy/running |
| 7. Projects Dir | Creates `projects/` directory for your apps |
| 8. mkcert CA | Runs `mkcert -install` to trust local CA (best effort) |
| 9. Flask API | Starts `python3 server/app.py` in background on port 5000 |
| 10. Test VHost | Creates `testapp.local` vhost via API |
| 11. Verify | Hits all API endpoints and reports PASS/FAIL |
| 12. Browser | Opens `http://localhost:5000` if `DISPLAY` set and `xdg-open` available |

### Installer Options

```bash
# Dry-run: only check prerequisites
./cloud/install-local.sh --preflight

# Custom target directory
DSTACK_DIR=~/my-devstack ./cloud/install-local.sh

# Skip browser launch
SKIP_BROWSER=1 ./cloud/install-local.sh
```

---

## Manual Setup (Developer Mode)

If you prefer to run each step manually (e.g., for development/debugging):

### 1. Clone Repository

```bash
git clone https://github.com/dgi-dev/DStack.git
cd DStack
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env and set secure passwords:
#   DB_ROOT_PASSWORD=your_secure_root_password
#   DB_PASSWORD=your_secure_user_password
vim .env
```

**Required `.env` variables:**

| Variable | Description | Example |
|----------|-------------|---------|
| `COMPOSE_PROJECT_NAME` | Docker Compose project prefix | `devstack` |
| `NGINX_PORT` | Host port for nginx HTTP | `80` |
| `PHP_VERSION` | PHP version for php-fpm image | `8.2` |
| `MYSQL_PORT` | Host port for MySQL | `3306` |
| `PHPMYADMIN_PORT` | Host port for phpMyAdmin | `8080` |
| `REDIS_PORT` | Host port for Redis | `6379` |
| `DB_ROOT_PASSWORD` | MySQL root password | `changeme` |
| `DB_NAME` | Default database name | `devstack` |
| `DB_USER` | MySQL user | `devstack` |
| `DB_PASSWORD` | MySQL user password | `changeme` |
| `APP_PORT` | Flask API port | `5000` |
| `FLASK_DEBUG` | Flask debug mode | `false` |

### 3. Build and Start Docker Stack

```bash
# Build images
docker compose -f docker/docker-compose.yml build

# Start services in background
docker compose -f docker/docker-compose.yml up -d

# Verify all containers are running
docker compose -f docker/docker-compose.yml ps
```

Expected output (all `healthy` or `running`):

```
NAME                     STATUS
devstack-nginx           running
devstack-php             running
devstack-mysql           healthy
devstack-phpmyadmin      running
devstack-redis           healthy
```

### 4. Install Local CA (mkcert)

```bash
mkcert -install
# Creates and trusts a local CA in system/browser trust stores
# Requires libnss3-tools on Linux
```

### 5. Start Flask API Server

```bash
# Option A: Direct (foreground)
python3 server/app.py

# Option B: Background (like installer)
nohup python3 server/app.py >> devstack.log 2>&1 &
echo $! > .flask.pid
```

The API will be available at `http://localhost:5000`.

### 6. Create a Virtual Host

```bash
# Via API
curl -s -X POST http://localhost:5000/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local", "framework": "laravel"}'

# Or via TUI
python3 cli/tui.py
```

### 7. Add `/etc/hosts` Entry

For local domains to resolve, add entries to `/etc/hosts`:

```bash
# Manual
echo "127.0.0.1 myapp.local testapp.local" | sudo tee -a /etc/hosts

# Or use the helper (if available)
sudo ./scripts/add-hosts.sh myapp.local testapp.local
```

> **Note**: The installer attempts to add `testapp.local` automatically. For custom domains, you must add them manually.

---

## Accessing Services

| Service | URL / Connection | Credentials |
|---------|------------------|-------------|
| **Dashboard** | http://localhost:5000 | — |
| **phpMyAdmin** | http://localhost:8080 | Server: `mysql`, User: `root`, Pass: `DB_ROOT_PASSWORD` |
| **MySQL** | `mysql -h 127.0.0.1 -P 3306 -u root -p` | `DB_ROOT_PASSWORD` |
| **Redis** | `redis-cli -h 127.0.0.1 -p 6379` | — |
| **Test VHost** | http://testapp.local | — |
| **Your VHost** | http://myapp.local | — |

---

## Managing the Stack

### Stop All Services

```bash
# Stop Flask API
kill $(cat .flask.pid 2>/dev/null) 2>/dev/null || true

# Stop Docker stack
docker compose -f docker/docker-compose.yml down
```

### Restart Everything

```bash
docker compose -f docker/docker-compose.yml restart
# Then restart Flask if needed
python3 server/app.py
```

### View Logs

```bash
# Docker service logs
docker compose -f docker/docker-compose.yml logs -f nginx
docker compose -f docker/docker-compose.yml logs -f php

# Flask API log
tail -f devstack.log
```

### Run Tests

```bash
# All server tests
python3 server/test_services.py
python3 server/test_vhosts.py
python3 server/test_ssl.py
python3 server/test_rds_tunnel.py
python3 server/test_logs.py
python3 server/test_backup.py

# Or with pytest
python3 -m pytest server/test_*.py -v

# TUI tests
python3 -m pytest cli/test_tui.py -q
```

---

## Adding Your Own Project

1. Create a project directory under `projects/`:

```bash
mkdir -p projects/myapp.local/public
```

2. Add an `index.php` (or Laravel/Symfony/WordPress project):

```php
<!-- projects/myapp.local/public/index.php -->
<?php
echo "<h1>Hello from myapp.local!</h1>";
phpinfo();
```

3. Create a vhost pointing to it:

```bash
curl -s -X POST http://localhost:5000/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local", "framework": "php", "root": "/var/www/projects/myapp.local/public"}'
```

4. Add to `/etc/hosts`:

```bash
echo "127.0.0.1 myapp.local" | sudo tee -a /etc/hosts
```

5. Visit `http://myapp.local` in your browser.

---

## Enabling HTTPS (Local)

### Option A: mkcert (Local CA, Trusted)

```bash
# Via API
curl -s -X POST http://localhost:5000/api/ssl/local \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local"}'

# Or via dashboard: SSL tab → "Create Local Cert"
```

Certificates are stored in `docker/ssl/` and automatically included in nginx config.

### Option B: Let's Encrypt (Production Domains Only)

Requires a real domain pointing to your machine's public IP and port 80 accessible.

```bash
curl -s -X POST http://localhost:5000/api/ssl/letsencrypt \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.example.com", "email": "you@example.com", "mode": "standalone"}'
```

---

## Troubleshooting

### Docker Permission Denied

```bash
sudo usermod -aG docker $USER
newgrp docker  # or log out/in
```

### Port Already in Use

```bash
# Check what's using port 80/443/5000/3306/8080
sudo ss -tlnp | grep -E ':80|:443|:5000|:3306|:8080'

# Change ports in .env (e.g., NGINX_PORT=8080, APP_PORT=5001)
```

### MySQL Not Healthy

```bash
# Check logs
docker compose -f docker/docker-compose.yml logs mysql

# Common fix: ensure .env passwords match and restart
docker compose -f docker/docker-compose.yml restart mysql
```

### Flask API Not Starting

```bash
# Check log
cat devstack.log

# Common issues:
# - Port 5000 in use: change APP_PORT in .env
# - Missing deps: pip3 install -r server/requirements.txt
# - Python version: need 3.10+
```

### VHost Returns 404/502

1. Check nginx config was generated: `ls docker/vhosts/`
2. Check nginx logs: `docker compose -f docker/docker-compose.yml logs nginx`
3. Verify project root exists and has `public/index.php`
4. Ensure `/etc/hosts` has the domain

### mkcert Not Trusted

```bash
# Reinstall CA
mkcert -uninstall
mkcert -install

# On Linux, ensure libnss3-tools is installed
sudo apt install libnss3-tools
```

---

## Next Steps

- Read [API.md](API.md) for full API reference
- Read [TESTING.md](TESTING.md) for test scenarios
- Read [EC2_DEPLOYMENT.md](EC2_DEPLOYMENT.md) for production deployment
- Explore the [sample Laravel app](../projects/sample-app/README.md)