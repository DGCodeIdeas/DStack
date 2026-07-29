#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/dstack-panel"
REPO="https://github.com/DGCodeIdeas/DStack.git"
PANEL_SUBDOMAIN="${PANEL_SUBDOMAIN:-panel.chadadigital.com}"

echo "==> DStack Panel init.sh (blue-green)"
echo "==> Panel subdomain: ${PANEL_SUBDOMAIN}"

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

# 3.1 Ensure www-data can access Docker
if ! getent group docker | grep -qw www-data; then
    echo "==> Adding www-data to docker group..."
    usermod -aG docker www-data
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
    sed -i "s|^APP_URL=.*|APP_URL=https://${PANEL_SUBDOMAIN}|" "${ROOT}/.env"
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

# 10. Install systemd template
cp "${ROOT}/systemd/dstack-panel@.service" /etc/systemd/system/dstack-panel@.service
systemctl daemon-reload

# 11. Create blue-green env files from .env if missing
for COLOR in green blue; do
    ENV_FILE="${ROOT}/.env.${COLOR}"
    if [ ! -f "${ENV_FILE}" ]; then
        cp "${ROOT}/.env" "${ENV_FILE}"
        sed -i "s/^PORT=.*/PORT=$([ "${COLOR}" = "green" ] && echo 5000 || echo 5001)/" "${ENV_FILE}" || true
        sed -i "s|^APP_URL=.*|APP_URL=https://${PANEL_SUBDOMAIN}|" "${ENV_FILE}" || true
    fi
done

# Default port if not set
for COLOR in green blue; do
    ENV_FILE="${ROOT}/.env.${COLOR}"
    if ! grep -q '^PORT=' "${ENV_FILE}" 2>/dev/null; then
        PORT=$([ "${COLOR}" = "green" ] && echo 5000 || echo 5001)
        echo "PORT=${PORT}" >> "${ENV_FILE}"
    fi
    if ! grep -q '^APP_URL=' "${ENV_FILE}" 2>/dev/null; then
        echo "APP_URL=https://${PANEL_SUBDOMAIN}" >> "${ENV_FILE}"
    fi
done

# 12. Start both instances
for COLOR in green blue; do
    systemctl enable --now "dstack-panel@${COLOR}.service"
done

# 13. Set active instance (default: green)
echo "green" > "${ROOT}/.active_instance"

# 14. Deploy nginx vhost
VHOST_SRC="${ROOT}/nginx/${PANEL_SUBDOMAIN}.conf"
if [ ! -f "${VHOST_SRC}" ]; then
    VHOST_SRC="${ROOT}/nginx/chadadigital.com.conf"
fi

VHOST_DEST="/etc/nginx/sites-available/${PANEL_SUBDOMAIN}.conf"
cp "${VHOST_SRC}" "${VHOST_DEST}"
ln -sf "${VHOST_DEST}" "/etc/nginx/sites-enabled/${PANEL_SUBDOMAIN}.conf"
nginx -t && systemctl reload nginx

# 15. Configure AWS Security Group (if aws-cli is available and configured)
if command -v aws &>/dev/null; then
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=ip-permission.protocol,Values=tcp" "Name=ip-permission.from-port,Values=22" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [ -n "${SG_ID}" ] && [ "${SG_ID}" != "None" ]; then
        echo "==> Configuring AWS Security Group ${SG_ID} for HTTP/HTTPS..."
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true
    fi
fi

echo ""
echo "DStack Panel running at https://${PANEL_SUBDOMAIN} (active: green)"
