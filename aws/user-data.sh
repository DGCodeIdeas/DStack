#!/bin/bash
# -------------------------------------------------------------------------
# AWS EC2 User-Data: DStack Panel Production Bootstrap (t3.small)
# -------------------------------------------------------------------------
# Deploys the DStack Panel Laravel app with Docker Compose stack,
# nginx + PHP-FPM serving, SSL, and hardened security.
#
# Required EC2 IAM permissions: EC2 describe/edit security groups
# Recommended: Attach the existing Chada-EC2-Role instance profile
# -------------------------------------------------------------------------

set -euo pipefail

# ===========================================================================
# Configuration — override via EC2 instance tags or environment variables
# ===========================================================================
PANEL_SUBDOMAIN="${PANEL_SUBDOMAIN:-panel.chadadigital.com}"
APP_ENV="${APP_ENV:-production}"
APP_KEY="${APP_KEY:-}"
DB_CONNECTION="${DB_CONNECTION:-sqlite}"
SSH_KEY_NAME="${SSH_KEY_NAME:-<redacted-rds-db>}"
AWS_REGION="${AWS_REGION:-eu-north-1}"
INSTANCE_ID="${INSTANCE_ID:-$(curl -s http://169.254.169.254/latest/meta-data/instance-id)}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
PHP_VERSION="${PHP_VERSION:-8.2}"
NGINX_PORT="${NGINX_PORT:-80}"
SSL_PORT="${SSL_PORT:-443}"

# DStack paths (must match config/dstack.php defaults)
ROOT="/opt/dstack-panel"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yml"
ENV_FILE="${ROOT}/.env"
VHOSTS_DIR="${ROOT}/docker/vhosts"
SSL_DIR="${ROOT}/docker/ssl"
PROJECTS_DIR="${ROOT}/projects"
BACKUPS_DIR="${ROOT}/backups"
DB_PATH="${ROOT}/storage/database/panel.db"
REPO_URL="https://github.com/DGCodeIdeas/DStack.git"

# Colors for log output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ===========================================================================
# Phase 1: System Preparation
# ===========================================================================
log_info "Phase 1: System preparation"

export DEBIAN_FRONTEND=noninteractive

# Update OS and install base packages
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl \
    git \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    ufw \
    fail2ban \
    logrotate \
    htop \
    ncdu \
    cron \
    rsyslog

# ===========================================================================
# Phase 2: Swap Space (safety for t3.small with 2 GB RAM)
# ===========================================================================
log_info "Phase 2: Swap space configuration (${SWAP_SIZE})"

if [ ! -f /swapfile ]; then
    fallocate -l "${SWAP_SIZE}" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Lower swappiness to prefer keeping app data in RAM
    sysctl vm.swappiness=10
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    log_info "Swap activated: ${SWAP_SIZE} at swappiness=10"
else
    log_info "Swap file already exists — skipping"
fi

# ===========================================================================
# Phase 3: Install PHP ${PHP_VERSION} and Extensions
# ===========================================================================
log_info "Phase 3: PHP ${PHP_VERSION} installation"

# PPA for up-to-date PHP on Ubuntu 22.04/24.04
if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
    add-apt-repository ppa:ondrej/php -y
    apt-get update -qq
fi

apt-get install -y -qq \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-sqlite3 \
    php${PHP_VERSION}-pdo \
    php${PHP_VERSION}-pdo-sqlite \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-tokenizer \
    php${PHP_VERSION}-fileinfo

# Verify PHP-FPM socket path
PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
if [ ! -S "${PHP_FPM_SOCK}" ]; then
    # Try alternative socket paths
    for sock in \
        "/run/php/php${PHP_VERSION}-fpm.sock" \
        "/var/run/php/php${PHP_VERSION}-fpm.sock" \
        "/run/php-fpm${PHP_VERSION}.sock"; do
        if [ -S "${sock}" ]; then
            PHP_FPM_SOCK="${sock}"
            break
        fi
    done
fi

log_info "PHP-FPM socket: ${PHP_FPM_SOCK}"

# ===========================================================================
# Phase 4: Install Docker + Compose v2
# ===========================================================================
log_info "Phase 4: Docker and Compose installation"

if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log_info "Docker installed and enabled"
else
    log_info "Docker already installed"
fi

if ! docker compose version &>/dev/null; then
    apt-get install -y -qq docker-compose-plugin
    log_info "Docker Compose plugin installed"
else
    log_info "Docker Compose already installed"
fi

# Ensure www-data can interact with Docker
if ! getent group docker | grep -qw www-data; then
    usermod -aG docker www-data
    log_info "Added www-data to docker group"
fi

# ===========================================================================
# Phase 5: Install Composer (global)
# ===========================================================================
log_info "Phase 5: Composer installation"

if ! command -v composer &>/dev/null; then
    EXPECTED_CHECKSUM="$(curl -sL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]; then
        log_error "Composer installer checksum mismatch — aborting"
        rm -f composer-setup.php
        exit 1
    fi

    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
    chmod +x /usr/local/bin/composer
    log_info "Composer installed globally"
else
    log_info "Composer already installed: $(composer --version 2>/dev/null | head -1)"
fi

# ===========================================================================
# Phase 6: Deploy Application Code
# ===========================================================================
log_info "Phase 6: Application deployment"

mkdir -p "${ROOT}"
chown -R ubuntu:www-data "${ROOT}"
chmod -R 775 "${ROOT}"

if [ ! -d "${ROOT}/.git" ]; then
    log_info "Cloning repository: ${REPO_URL}"
    git clone "${REPO_URL}" "${ROOT}"
else
    log_info "Repository already present — pulling latest"
    cd "${ROOT}"
    git fetch origin --tags --quiet
    git pull origin main --quiet || git pull origin master --quiet || true
fi

cd "${ROOT}"

# Set ownership for web operations
chown -R www-data:www-data "${ROOT}"

# ===========================================================================
# Phase 7: Install PHP Dependencies (Production)
# ===========================================================================
log_info "Phase 7: PHP dependency installation (production)"

composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction \
    --working-dir="${ROOT}" 2>&1 | tail -5

# ===========================================================================
# Phase 8: Configure .env
# ===========================================================================
log_info "Phase 8: Environment configuration"

if [ ! -f "${ROOT}/.env" ]; then
    cp "${ROOT}/.env.example" "${ROOT}/.env"
fi

# Update key .env values
sed -i "s|^APP_ENV=.*|APP_ENV=${APP_ENV}|" "${ROOT}/.env"
sed -i "s|^APP_URL=.*|APP_URL=https://${PANEL_SUBDOMAIN}|" "${ROOT}/.env"
sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${ROOT}/.env"
sed -i "s|^LOG_LEVEL=.*|LOG_LEVEL=warning|" "${ROOT}/.env"
sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=${DB_CONNECTION}|" "${ROOT}/.env"

if [ "${DB_CONNECTION}" = "sqlite" ]; then
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=database/panel.db|" "${ROOT}/.env"
    mkdir -p "${ROOT}/storage/database"
    touch "${DB_PATH}"
    chmod 664 "${DB_PATH}"
    chown www-data:www-data "${DB_PATH}"
fi

# Update DStack paths to match production
sed -i "s|^DSTACK_ROOT=.*|DSTACK_ROOT=${ROOT}|" "${ROOT}/.env"
sed -i "s|^DSTACK_DOCKER_COMPOSE_FILE=.*|DSTACK_DOCKER_COMPOSE_FILE=${COMPOSE_FILE}|" "${ROOT}/.env"
sed -i "s|^DSTACK_VHOSTS_DIR=.*|DSTACK_VHOSTS_DIR=${VHOSTS_DIR}|" "${ROOT}/.env"
sed -i "s|^DSTACK_SSL_DIR=.*|DSTACK_SSL_DIR=${SSL_DIR}|" "${ROOT}/.env"
sed -i "s|^DSTACK_PROJECTS_DIR=.*|DSTACK_PROJECTS_DIR=${PROJECTS_DIR}|" "${ROOT}/.env"
sed -i "s|^DSTACK_BACKUPS_DIR=.*|DSTACK_BACKUPS_DIR=${BACKUPS_DIR}|" "${ROOT}/.env"

# Ensure required directories exist with correct permissions
mkdir -p "${VHOSTS_DIR}" "${SSL_DIR}" "${PROJECTS_DIR}" "${BACKUPS_DIR}"
mkdir -p "${ROOT}/storage/logs" "${ROOT}/storage/framework/cache" \
         "${ROOT}/storage/framework/sessions" "${ROOT}/storage/framework/views"
mkdir -p "${ROOT}/bootstrap/cache"

chown -R www-data:www-data \
    "${ROOT}/storage" \
    "${ROOT}/bootstrap/cache" \
    "${VHOSTS_DIR}" \
    "${SSL_DIR}" \
    "${PROJECTS_DIR}" \
    "${BACKUPS_DIR}" \
    "${ROOT}/storage/database" 2>/dev/null || true

chmod -R 775 "${ROOT}/storage" "${ROOT}/bootstrap/cache"

# ===========================================================================
# Phase 9: Application Key + Optimization
# ===========================================================================
log_info "Phase 9: Application key and optimization"

# Generate APP_KEY if missing or empty
if ! grep -q '^APP_KEY=base64:' "${ROOT}/.env" 2>/dev/null; then
    php "${ROOT}/artisan" key:generate --force
    log_info "APP_KEY generated"
else
    log_info "APP_KEY already set"
fi

# Laravel production optimization
php "${ROOT}/artisan" config:cache --force
php "${ROOT}/artisan" route:cache --force
php "${ROOT}/artisan" view:cache --force
php "${ROOT}/artisan" event:cache --force
log_info "Laravel cache optimized"

# ===========================================================================
# Phase 10: Database Migrations
# ===========================================================================
log_info "Phase 10: Database migrations"

# Only run migrations for SQLite (the default production setup)
if [ "${DB_CONNECTION}" = "sqlite" ] && [ -f "${DB_PATH}" ]; then
    php "${ROOT}/artisan" migrate --force 2>&1 | tail -3 || log_warn "Migration may have failed — check logs"
fi

# ===========================================================================
# Phase 11: SSL Certificates (Let's Encrypt)
# ===========================================================================
log_info "Phase 11: SSL certificate setup"

apt-get install -y -qq certbot python3-certbot-nginx

# Create SSL directory
mkdir -p "${SSL_DIR}"
chown -R www-data:www-data "${SSL_DIR}"

# Ensure nginx is running so certbot can verify domain ownership
systemctl enable --now nginx || true

# Obtain certificate (only if nginx is properly configured)
# This is deferred to Phase 14 after nginx is configured
# certbot will be run with --nginx plugin after initial setup
SSL_CERT_READY=false

# ===========================================================================
# Phase 12: PHP-FPM Tuning for 2 GB RAM (t3.small)
# ===========================================================================
log_info "Phase 12: PHP-FPM resource optimization"

FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

if [ -f "${FPM_CONF}" ]; then
    # Dynamic process manager — tuned for 2 GB RAM
    sed -i 's/^pm = .*/pm = dynamic/' "${FPM_CONF}"
    sed -i 's/^pm.max_children = .*/pm.max_children = 6/' "${FPM_CONF}"
    sed -i 's/^pm.start_servers = .*/pm.start_servers = 3/' "${FPM_CONF}"
    sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "${FPM_CONF}"
    sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 4/' "${FPM_CONF}"
    sed -i 's/^pm.max_requests = .*/pm.max_requests = 1000/' "${FPM_CONF}"

    # Prevent FPM from running out of file descriptors
    sed -i 's/^;rlimit_files = .*/rlimit_files = 65535/' "${FPM_CONF}"

    # Disable dangerous PHP settings for production
    sed -i 's/^expose_php = .*/expose_php = Off/' /etc/php/${PHP_VERSION}/fpm/php.ini 2>/dev/null || true
    sed -i 's/^display_errors = .*/display_errors = Off/' /etc/php/${PHP_VERSION}/fpm/php.ini 2>/dev/null || true
    sed -i 's/^log_errors = .*/log_errors = On/' /etc/php/${PHP_VERSION}/fpm/php.ini 2>/dev/null || true

    systemctl restart "php${PHP_VERSION}-fpm"
    log_info "PHP-FPM tuned: pm=dynamic, max_children=6"
else
    log_warn "PHP-FPM config not found at ${FPM_CONF} — skipping tuning"
fi

# ===========================================================================
# Phase 13: Supervisor Configuration for Queue Workers
# ===========================================================================
log_info "Phase 13: Supervisor configuration"

SYSTEMD_DIR="/etc/systemd/system"

# Set up the DStack systemd service template
if [ -f "${ROOT}/systemd/dstack-panel@.service" ]; then
    cp "${ROOT}/systemd/dstack-panel@.service" "${SYSTEMD_DIR}/dstack-panel@.service"
    systemctl daemon-reload
    log_info "DStack systemd service template installed"
fi

# Supervisor queue worker config (for Laravel queue:work if using async driver)
mkdir -p /etc/supervisor/conf.d

cat > /etc/supervisor/conf.d/dstack-worker.conf << 'SUPERVISOR_EOF'
[program:dstack-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /opt/dstack-panel/artisan queue:work --sleep=3 --tries=3 --max-time=3600 --stop-when-empty
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/opt/dstack-panel/storage/logs/worker.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=5
stopwaitsecs=3600
SUPERVISOR_EOF

systemctl enable --now supervisor || true
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
log_info "Supervisor configured for queue worker"

# ===========================================================================
# Phase 14: Nginx + PHP-FPM (Direct PHP Serving)
# ===========================================================================
log_info "Phase 14: Nginx + PHP-FPM configuration (direct PHP serving)"

# Remove default site if present
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/nginx/conf.d/upstreams.conf 2>/dev/null || true

# Create PHP-FPM pool for the DStack Panel
FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/dstack.conf"
mkdir -p /etc/php/${PHP_VERSION}/fpm/pool.d

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

chdir = /opt/dstack-panel

php_admin_value[error_log] = /opt/dstack-panel/storage/logs/php-fpm-error.log
php_admin_flag[log_errors] = on

env[APP_ENV] = production
env[APP_DEBUG] = false
FPM_POOL_EOF

# Disable the default www pool to avoid socket conflicts
sed -i 's/^pm = .*/pm = off/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf 2>/dev/null || true

# Server block: nginx serves PHP directly via FPM (no reverse proxy to artisan serve)
NGINX_CONF="/etc/nginx/sites-available/${PANEL_SUBDOMAIN}.conf"

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > "${NGINX_CONF}" << NGINX_CONF_EOF
# HTTP → HTTPS redirect
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name ${PANEL_SUBDOMAIN};
    return 301 https://\$host\$request_uri;
}

# HTTPS server — Laravel panel served directly via PHP-FPM
server {
    listen ${SSL_PORT} ssl http2;
    listen [::]:${SSL_PORT} ssl http2;
    server_name ${PANEL_SUBDOMAIN};

    root /opt/dstack-panel/public;
    index index.php index.html;

    client_max_body_size 64M;

    ssl_certificate     /etc/letsencrypt/live/${PANEL_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_SUBDOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    charset utf-8;

    # Static assets — served directly by nginx, bypass PHP entirely
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location /favicon.ico { access_log off; log_not_found off; }
    location /robots.txt  { access_log off; log_not_found off; }
    location /well-known  { root /var/www/html; allow all; }

    # Laravel application routing — passed to PHP-FPM
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP processing via FPM socket
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-dstack.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 3600;
    }

    # Deny access to hidden files
    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Deny access to sensitive files
    location ~* \\.(env|git|svn|htaccess|md|yml|yaml)$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}
NGINX_CONF_EOF

ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${PANEL_SUBDOMAIN}.conf"

# Validate and reload nginx
if nginx -t 2>/dev/null; then
    systemctl enable --now nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    log_info "Nginx configured with PHP-FPM (direct serving)"
else
    log_warn "Nginx config test failed — will retry after SSL certificate is obtained"
fi

# ===========================================================================
# Phase 15: SSL/TLS with Let's Encrypt
# ===========================================================================
log_info "Phase 15: Let's Encrypt SSL certificate"

# Ensure the domain resolves to this instance before requesting cert
# (This is a prerequisite — the DNS must point to the EC2 public IP)
if certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --email "admin@${PANEL_SUBDOMAIN}" \
    -d "${PANEL_SUBDOMAIN}" \
    --rsa-key-size 4096 \
    --force-renewal 2>/dev/null; then
    SSL_CERT_READY=true
    log_info "SSL certificate obtained for ${PANEL_SUBDOMAIN}"

    # Reload nginx to pick up the new certificates
    systemctl reload nginx 2>/dev/null || true

    # Set up automatic renewal via cron
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    log_info "Certbot auto-renewal cron job configured"
else
    log_warn "SSL certificate could not be obtained — ensure DNS ${PANEL_SUBDOMAIN} points to this instance"
    log_warn "Run manually: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
fi

# ===========================================================================
# Phase 16: Firewall Hardening (UFW)
# ===========================================================================
log_info "Phase 16: Firewall configuration"

# Reset to defaults
ufw --force reset

# Default policies: deny incoming, allow outgoing
ufw default deny incoming
ufw default allow outgoing

# Allow SSH on the configured key's port
ufw allow 22/tcp comment 'SSH'

# Allow HTTP (certbot needs port 80 for HTTP-01 challenge)
ufw allow 80/tcp comment 'HTTP (Let'\''s Encrypt)'

# Allow HTTPS
ufw allow 443/tcp comment 'HTTPS'

# Enable UFW
echo "y" | ufw enable

# Limit SSH to reduce brute-force attempts
ufw limit 22/tcp 2>/dev/null || true

log_info "Firewall enabled: SSH(22), HTTP(80), HTTPS(443) allowed"

# ===========================================================================
# Phase 17: Fail2ban for SSH Protection
# ===========================================================================
log_info "Phase 17: Fail2ban hardening"

cat > /etc/fail2ban/jail.local << FAIL2BAN_EOF
[DEFAULT]
banaction = iptables-multiport
bantime = 600
findtime = 600
maxretry = 3
backend = auto

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
FAIL2BAN_EOF

systemctl enable --now fail2ban || true
log_info "Fail2ban enabled with SSH brute-force protection (3 attempts / 1 hour ban)"

# ===========================================================================
# Phase 18: Log Rotation
# ===========================================================================
log_info "Phase 18: Log rotation configuration"

cat > /etc/logrotate.d/dstack-panel << LOGROTATE_EOF
/opt/dstack-panel/storage/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0664 www-data www-data
    sharedscripts
    postrotate
        if [ -f /var/run/php/php${PHP_VERSION}-fpm.pid ]; then
            kill -USR2 \$(cat /var/run/php/php${PHP_VERSION}-fpm.pid)
        fi
    endscript
}

/var/log/supervisor/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        supervisorctl reload > /dev/null 2>&1 || true
    endscript
}
LOGROTATE_EOF

log_info "Log rotation configured (14 days for app logs, 7 days for supervisor)"

# ===========================================================================
# Phase 19: Cron Jobs for Laravel Scheduler
# ===========================================================================
log_info "Phase 19: Laravel scheduler cron"

# Run Laravel scheduler every minute as www-data
(crontab -u www-data -l 2>/dev/null | grep -v 'artisan schedule'; echo "* * * * * cd /opt/dstack-panel && php artisan schedule:run >> /opt/dstack-panel/storage/logs/scheduler.log 2>&1") | crontab -u www-data -

log_info "Laravel scheduler cron configured for www-data user"

# ===========================================================================
# Phase 20: Start Application Services
# ===========================================================================
log_info "Phase 20: Starting all services"

# Enable the DStack systemd service (oneshot deployment trigger)
if [ -f "${SYSTEMD_DIR}/dstack-panel@.service" ]; then
    systemctl enable "dstack-panel@.service" 2>/dev/null || true
fi

# Ensure Docker Compose stack is running
if [ -f "${COMPOSE_FILE}" ]; then
    cd "${ROOT}"
    sudo -u www-data docker compose up -d --remove-orphans 2>/dev/null || \
        log_warn "Docker Compose stack start failed — check ${COMPOSE_FILE}"
fi

# ===========================================================================
# Phase 21: Health Check Verification
# ===========================================================================
log_info "Phase 21: Health verification"

sleep 3

# Check PHP-FPM
if pgrep -x "php-fpm${PHP_VERSION}" > /dev/null; then
    log_info "PHP-FPM ${PHP_VERSION}: running"
else
    log_warn "PHP-FPM ${PHP_VERSION}: not running — attempting restart"
    systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
fi

# Check nginx
if systemctl is-active --quiet nginx; then
    log_info "Nginx: running"
else
    log_warn "Nginx: not running — attempting restart"
    systemctl restart nginx 2>/dev/null || true
fi

# Check Docker
if docker info > /dev/null 2>&1; then
    log_info "Docker: running"
else
    log_warn "Docker: not running — attempting restart"
    systemctl restart docker 2>/dev/null || true
fi

# Check database
if [ "${DB_CONNECTION}" = "sqlite" ] && [ -f "${DB_PATH}" ]; then
    log_info "SQLite database: ready"
fi

# ===========================================================================
# Phase 22: Final Output
# ===========================================================================
log_info "========================================="
log_info " DStack Panel bootstrap complete"
log_info "========================================="
log_info "  Application root: ${ROOT}"
log_info "  Panel URL: https://${PANEL_SUBDOMAIN}"
log_info "  PHP version: ${PHP_VERSION}"
log_info "  Database: ${DB_CONNECTION}"
log_info "  SSL ready: ${SSL_CERT_READY}"
log_info "  Docker Compose stack: $(docker compose -f ${COMPOSE_FILE} ps 2>/dev/null | grep -c running || echo 0) running"
log_info ""
log_info " Next steps:"
log_info "  1. Update DNS ${PANEL_SUBDOMAIN} → this instance's public IP"
log_info "  2. If SSL failed, run: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
log_info "  3. Check logs: tail -f ${ROOT}/storage/logs/laravel.log"
log_info "  4. Re-run artisan: php ${ROOT}/artisan optimize"
log_info "========================================="