#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/dstack-panel"
REPO="https://github.com/DGCodeIdeas/DStack.git"
PANEL_SUBDOMAIN="${PANEL_SUBDOMAIN:-panel.chadadigital.com}"
PHP_VERSION="${PHP_VERSION:-8.2}"

echo "==> DStack Panel init.sh (PHP-FPM + nginx)"
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

# 2. Install PHP ${PHP_VERSION} + extensions + FPM + nginx (if missing)
if ! command -v php &>/dev/null; then
    echo "==> Installing PHP + FPM + nginx..."
    apt-get update -qq
    apt-get install -y -qq \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-pdo \
        php${PHP_VERSION}-pdo-sqlite \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-posix \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-gd \
        nginx \
        certbot \
        python3-certbot-nginx
fi

# 3. Install Composer (if missing)
if ! command -v composer &>/dev/null; then
    echo "==> Installing Composer..."
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
fi

# 4. Ensure www-data can access Docker
if ! getent group docker | grep -qw www-data; then
    echo "==> Adding www-data to docker group..."
    usermod -aG docker www-data
fi

# 5. Clone/update repo
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

# 6. Install PHP dependencies
echo "==> Installing PHP dependencies..."
composer install --no-dev --optimize-autoloader

# 7. Configure .env
echo "==> Configuring .env..."
if [ ! -f "${ROOT}/.env" ]; then
    cp "${ROOT}/.env.example" "${ROOT}/.env"
fi

sed -i "s|^APP_URL=.*|APP_URL=https://${PANEL_SUBDOMAIN}|" "${ROOT}/.env"
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${ROOT}/.env"
sed -i "s|^APP_ENV=.*|APP_ENV=production|" "${ROOT}/.env"
sed -i "s|^LOG_LEVEL=.*|LOG_LEVEL=warning|" "${ROOT}/.env"
sed -i "s|^DSTACK_ROOT=.*|DSTACK_ROOT=${ROOT}|" "${ROOT}/.env"
sed -i "s|^DSTACK_VHOSTS_DIR=.*|DSTACK_VHOSTS_DIR=${ROOT}/docker/vhosts|" "${ROOT}/.env"
sed -i "s|^DSTACK_SSL_DIR=.*|DSTACK_SSL_DIR=${ROOT}/docker/ssl|" "${ROOT}/.env"

# 8. Generate APP_KEY if missing
if grep -q '^APP_KEY=$' "${ROOT}/.env" 2>/dev/null || ! grep -q '^APP_KEY=' "${ROOT}/.env" 2>/dev/null; then
    php artisan key:generate --force
fi

# 9. Ensure database directory and file exist
mkdir -p "${ROOT}/storage/database"
touch "${ROOT}/storage/database/panel.db"
chmod 664 "${ROOT}/storage/database/panel.db"
chown www-data:www-data "${ROOT}/storage/database/panel.db"

# 10. Ensure required directories exist with correct permissions
mkdir -p "${ROOT}/storage/logs" "${ROOT}/storage/framework/cache" \
         "${ROOT}/storage/framework/sessions" "${ROOT}/storage/framework/views"
mkdir -p "${ROOT}/bootstrap/cache" "${ROOT}/docker/vhosts" "${ROOT}/docker/ssl"
chown -R www-data:www-data "${ROOT}/storage" "${ROOT}/bootstrap/cache" "${ROOT}/docker"
chmod -R 775 "${ROOT}/storage" "${ROOT}/bootstrap/cache"

# 11. Run migrations
echo "==> Running migrations..."
php artisan migrate --force

# 12. Laravel production optimization
echo "==> Optimizing Laravel cache..."
php artisan config:cache --force
php artisan route:cache --force
php artisan view:cache --force
php artisan event:cache --force

# 13. Configure PHP-FPM pool for DStack Panel
echo "==> Configuring PHP-FPM pool..."
FPM_POOL_DIR="/etc/php/${PHP_VERSION}/fpm/pool.d"
FPM_POOL_CONF="${FPM_POOL_DIR}/dstack.conf"

cat > "${FPM_POOL_CONF}" << FPM_POOL_EOF
[dstack]
user = www-data
group = www-data
listen = /run/php/php${PHP_VERSION}-fpm-dstack.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 6
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 4
pm.max_requests = 1000

chdir = ${ROOT}

php_admin_value[error_log] = ${ROOT}/storage/logs/php-fpm-error.log
php_admin_flag[log_errors] = on

env[APP_ENV] = production
env[APP_DEBUG] = false
FPM_POOL_EOF

# Disable default www pool to avoid socket conflicts
if [ -f "${FPM_POOL_DIR}/www.conf" ]; then
    sed -i 's/^pm = .*/pm = off/' "${FPM_POOL_DIR}/www.conf" 2>/dev/null || true
fi

# 14. Configure nginx to serve panel directly via PHP-FPM
echo "==> Configuring nginx..."
NGINX_CONF="/etc/nginx/sites-available/${PANEL_SUBDOMAIN}.conf"

cat > "${NGINX_CONF}" << NGINX_CONF_EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_SUBDOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${PANEL_SUBDOMAIN};

    root ${ROOT}/public;
    index index.php index.html;

    client_max_body_size 64M;

    ssl_certificate     /etc/letsencrypt/live/${PANEL_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_SUBDOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    charset utf-8;

    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location /favicon.ico { access_log off; log_not_found off; }
    location /robots.txt  { access_log off; log_not_found off; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-dstack.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 3600;
    }

    location ~ /\. {
        deny all;
    }

    location ~* \.(env|git|svn|htaccess)$ {
        deny all;
    }
}
NGINX_CONF_EOF

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${PANEL_SUBDOMAIN}.conf"

# Validate and reload nginx
nginx -t 2>/dev/null && systemctl reload nginx || true

# 15. Start PHP-FPM and nginx
echo "==> Starting PHP-FPM and nginx..."
systemctl enable --now "php${PHP_VERSION}-fpm" 2>/dev/null || systemctl restart "php${PHP_VERSION}-fpm" || true
systemctl enable --now nginx 2>/dev/null || systemctl restart nginx || true

# 16. Obtain SSL certificate (if DNS points to this instance)
if certbot certonly --nginx --non-interactive --agree-tos \
    --email "admin@${PANEL_SUBDOMAIN}" \
    -d "${PANEL_SUBDOMAIN}" 2>/dev/null; then
    echo "==> SSL certificate obtained for ${PANEL_SUBDOMAIN}"
    systemctl reload nginx 2>/dev/null || true

    # Auto-renewal cron
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
else
    echo "==> SSL not obtained (DNS may not point here yet)"
    echo "==> Run manually: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
fi

# 17. Deploy Docker Compose stack (if compose file exists)
if [ -f "${ROOT}/docker/docker-compose.yml" ]; then
    echo "==> Starting Docker Compose stack..."
    cd "${ROOT}"
    sudo -u www-data docker compose up -d --remove-orphans 2>/dev/null || \
        echo "==> Docker Compose start deferred (will be triggered on first panel access)"
fi

# 18. Configure AWS Security Group (if aws-cli is available)
if command -v aws &>/dev/null; then
    echo "==> Configuring AWS Security Group..."
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=ip-permission.protocol,Values=tcp" "Name=ip-permission.from-port,Values=22" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [ -n "${SG_ID}" ] && [ "${SG_ID}" != "None" ]; then
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
            --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
            --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
            --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true
    fi
fi

echo ""
echo "DStack Panel running at https://${PANEL_SUBDOMAIN}"
echo "Panel root: ${ROOT}"
echo "PHP-FPM socket: /run/php/php${PHP_VERSION}-fpm-dstack.sock"
echo "Nginx config: ${NGINX_CONF}"
