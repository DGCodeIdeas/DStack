# Troubleshooting & FAQ

This document covers common issues, error codes, and recovery procedures for DStack Panel.

---

## General

### Panel shows "Whoops, looks like something went wrong"

**Cause:** `APP_KEY` is missing or `.env` has syntax errors.

**Fix:**
```bash
php artisan key:generate
php artisan config:clear
php artisan config:cache
```

---

### 500 Internal Server Error on all routes

**Cause:** Bootstrap cache corruption or missing `.env`.

**Fix:**
```bash
php artisan optimize:clear
php artisan config:cache
php artisan route:cache
```

---

## Blue-Green Deployment

### `dstack-panel@green` fails to start

**Cause:** Port 5000 is already in use, or `.env.green` has invalid `PORT`.

**Fix:**
```bash
# Check port usage
sudo ss -tlnp | grep 5000

# Fix env file
sudo nano /opt/dstack-panel/.env.green
# Ensure PORT=5000

# Restart
sudo systemctl daemon-reload
sudo systemctl restart dstack-panel@green
```

---

### nginx returns 502 Bad Gateway

**Cause:** Both blue-green instances are down, or nginx upstream points to stopped services.

**Fix:**
```bash
# Check instances
sudo systemctl status dstack-panel@green dstack-panel@blue

# Start at least one
sudo systemctl start dstack-panel@green

# Test nginx config
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx
```

---

### Deploy swaps to broken instance

**Cause:** Health check passed but app is actually broken.

**Fix:** Rolling back is automatic — nginx upstream includes both ports. If one is down, nginx routes to the other. Force rollback:

```bash
# Read current active
sudo cat /opt/dstack-panel/.active_instance

# If active=blue and broken, start green
sudo systemctl start dstack-panel@green

# Reload nginx (checks both upstreams)
sudo systemctl reload nginx
```

---

## Docker Services

### `docker compose ps` shows "unhealthy"

**Cause:** Container health check failing. Common with MySQL.

**Fix:**
```bash
# Inspect logs
docker compose -f docker/docker-compose.yml logs mysql

# Common: wrong password in .env
# Fix .env, then restart
docker compose -f docker/docker-compose.yml down
docker compose -f docker/docker-compose.yml up -d
```

---

### `Access denied for user 'root'@'%'`

**Cause:** `DB_ROOT_PASSWORD` in `.env` does not match MySQL root password.

**Fix:**
```bash
# Check current root password in MySQL container
docker compose -f docker/docker-compose.yml exec -T mysql \
  mysql -u root -p"$(grep DB_ROOT_PASSWORD .env | cut -d= -f2)" -e "SELECT 1"

# If that fails, reset:
docker compose -f docker/docker-compose.yml down
# Edit .env DB_ROOT_PASSWORD
docker compose -f docker/docker-compose.yml up -d
```

---

### Cannot connect to Docker daemon

**Cause:** User is not in `docker` group, or Docker is not running.

**Fix:**
```bash
# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker

# Or start Docker
sudo systemctl start docker
```

---

## Frontend / Assets

### `Vite manifest not found` or blank page

**Cause:** Assets not built, or `public/build` is empty.

**Fix:**
```bash
bun install --frozen-lockfile
bun run prod
# Or for development
bun run dev
```

---

### Changes not reflected in browser

**Cause:** Assets are cached, or you are viewing the built `public/assets/` instead of the Vite dev server.

**Fix:**
```bash
# Hard refresh: Ctrl+Shift+R
# Or clear cache
php artisan optimize:clear

# Ensure correct APP_URL in .env
```

---

## SSH / Tunnels

### `paramiko.SSHException: No authentication methods available`

**Cause:** Private key has a passphrase, or public key is not in `authorized_keys`.

**Fix:**
```bash
# Generate unencrypted key
ssh-keygen -t rsa -b 4096 -f ~/.ssh/devstack-ec2 -N ""

# Copy to EC2
ssh-copy-id -i ~/.ssh/devstack-ec2.pub ubuntu@<EC2_IP>
```

---

### RDS connection refused

**Cause:** RDS security group does not allow inbound from EC2 security group.

**Fix:**
```bash
# Edit RDS security group inbound rules:
# Type: MySQL/Aurora (3306)
# Source: sg-xxxxxxxxx (EC2 security group ID)
```

---

## Database

### `SQLSTATE[HY000] [14] unable to open database file`

**Cause:** SQLite database directory does not exist or is not writable.

**Fix:**
```bash
mkdir -p storage/database
touch storage/database/panel.db
chmod 664 storage/database/panel.db
php artisan migrate --force
```

---

### Migration fails with "table already exists"

**Cause:** Previous migrations were partially applied.

**Fix:**
```bash
# Check migration status
php artisan migrate:status

# Rollback last batch
php artisan migrate:rollback

# Or reset (destructive)
php artisan migrate:fresh --force
```

---

## Systemd

### `systemctl start dstack-panel@green` hangs

**Cause:** Port conflict or missing env file.

**Fix:**
```bash
# Check logs
journalctl -u dstack-panel@green -n 50 --no-pager

# Verify env file exists
ls -l /opt/dstack-panel/.env.green

# Check port
sudo ss -tlnp | grep 5000
```

---

### Both instances running but nginx serves old code

**Cause:** nginx is caching, or upstream order is wrong.

**Fix:**
```bash
# Clear nginx cache
sudo systemctl reload nginx

# Verify upstream config
grep -A5 'upstream panel_backend' /etc/nginx/sites-enabled/panel.chadadigital.com.conf

# Ensure active_instance is correct
sudo cat /opt/dstack-panel/.active_instance
```

---

## CI/CD

### GitHub Actions deploy fails at health check

**Cause:** New instance crashes on startup, or migrations fail.

**Fix:**
```bash
# SSH to EC2
ssh -i ~/.ssh/chadadigital.pem ubuntu@13.62.47.161

# Check logs
journalctl -u dstack-panel@blue -n 100 --no-pager
# or
journalctl -u dstack-panel@green -n 100 --no-pager

# Check nginx config
sudo nginx -t
```

---

### Rsync deploy succeeds but old code is running

**Cause:** `dstack-panel@blue` was not started, or `.env.blue` is stale.

**Fix:**
```bash
# Ensure instance is running
sudo systemctl restart dstack-panel@blue

# Sync .env from main if needed
cp /opt/dstack-panel/.env /opt/dstack-panel/.env.blue

# Restart again
sudo systemctl restart dstack-panel@blue
```

---

## FAQ

**Q: Can I run more than two instances?**
A: Yes, add more ports (5002, 5003, etc.) and extend the `upstream` in nginx. However, blue-green is the recommended pattern for zero-downtime deploys.

**Q: Does the panel support HTTPS out of the box?**
A: No. You must obtain certificates via Let's Encrypt (`api/ssl/letsencrypt`) or mkcert for local development, then configure nginx to listen on 443.

**Q: How do I back up the panel database?**
A: Use the panel UI or API: `POST /api/backup` with `{"database": "all"}`. Backups are stored in `BACKUPS_DIR` (default: `/opt/dstack-panel/backups`).

**Q: Can I use MySQL instead of SQLite?**
A: Yes. Set `DB_CONNECTION=mysql` and provide `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` in `.env`.

**Q: How do I update the panel?**
A: Push to `main` (triggers CI deploy), or run `php artisan dstack:update` on the server.

**Q: Why two `.env` files?**
A: Each blue-green instance needs its own `PORT` and potentially other overrides. The systemd template reads `.env.%i` (e.g., `.env.green`).

**Q: Is the panel accessible from the internet?**
A: Yes, once DNS points to the EC2 IP and security groups allow 80/443. Ensure you configure HTTPS and authentication for production.
