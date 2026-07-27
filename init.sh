#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# DStack Panel init.sh
# Replaces install-local.sh for the Laravel panel
# ──────────────────────────────────────────────

ROOT="/opt/dstack-panel"
REPO="https://github.com/DGCodeIdeas/chada.digital"

echo "==> DStack Panel init.sh"

# 1. Install Docker + Compose v2 (if missing)
if ! command -v docker &>/dev/null; then
    echo "==> Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version &>/dev/null; then
    echo "==> Installing Docker Compose plugin..."
    apt-get update -qq
    apt-get install -y -qq docker-compose-plugin
fi

# 2. Install PHP 8.2 + extensions (if missing)
if ! command -v php &>/dev/null; then
    echo "==> Installing PHP..."
    apt-get update -qq
    apt-get install -y -qq php8.2 php8.2-cli php8.2-pdo php8.2-pdo-sqlite php8.2-sqlite3 php8.2-mbstring php8.2-xml php8.2-curl php8.2-zip php8.2-posix
fi

# 3. Install Composer (if missing)
if ! command -v composer &>/dev/null; then
    echo "==> Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
fi

# 4. Clone/update repo
mkdir -p "${ROOT}"
if [ ! -d "${ROOT}/.git" ]; then
    echo "==> Cloning repo..."
    git clone "${REPO}" "${ROOT}"
else
    echo "==> Updating repo..."
    cd "${ROOT}"
    git pull
fi

cd "${ROOT}"

# 5. Install PHP dependencies
echo "==> Installing PHP dependencies..."
composer install --no-dev --optimize-autoloader

# 6. Copy .env.example → .env if .env doesn't exist
if [ ! -f "${ROOT}/.env" ]; then
    cp "${ROOT}/.env.example" "${ROOT}/.env"
fi

# 7. Generate APP_KEY if missing
if grep -q '^APP_KEY=$' "${ROOT}/.env" 2>/dev/null || ! grep -q '^APP_KEY=' "${ROOT}/.env" 2>/dev/null; then
    php artisan key:generate --force
fi

# 8. Ensure database directory and file exist
mkdir -p "${ROOT}/storage/database"
touch "${ROOT}/storage/database/panel.db"
chmod 664 "${ROOT}/storage/database/panel.db"
chown www-data:www-data "${ROOT}/storage/database/panel.db"

# 9. Run migrations
echo "==> Running migrations..."
php artisan migrate --force

# 10. Download panel assets from latest GitHub Release
echo "==> Downloading panel assets..."
LATEST_RELEASE=$(curl -s https://api.github.com/repos/DGCodeIdeas/chada.digital/releases/latest | grep -o '"tag_name": "[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "${LATEST_RELEASE}" ]; then
    curl -sL "https://github.com/DGCodeIdeas/chada.digital/releases/download/${LATEST_RELEASE}/panel-assets.tar.gz" | tar -xzf - -C "${ROOT}/public/"
fi

# 11. Install systemd service
cp "${ROOT}/systemd/dstack-panel.service" /etc/systemd/system/dstack-panel.service
systemctl daemon-reload
systemctl enable --now dstack-panel

echo ""
echo "DStack Panel running at http://YOUR_IP:5000"