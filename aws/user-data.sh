#!/bin/bash
# -------------------------------------------------------------------------
# AWS EC2 User-Data: DStack Panel Production Bootstrap (t3.small)
# -------------------------------------------------------------------------
# Deploys the DStack Panel Laravel app with PHP-FPM + nginx serving,
# SSL, chada.digital app integration, and hardened security.
#
# Usage: sudo bash -s < aws/user-data.sh
#        sudo bash /tmp/user-data.sh
#
# Idempotent: safe to re-run. Each step checks current system state
# and acts accordingly — no checkpoint files, no phase-tracking state.
# Key improvements:
#   - PHP-FPM config validated (php-fpm -t) before any restart
#   - PHP-FPM log permissions fixed automatically
#   - Post-restart verification that services are actually running
#   - Recovery logic for common failure modes (log permissions, config errors)
# -------------------------------------------------------------------------

set -euo pipefail

# PS4 fallback for SSH stdin execution (empty BASH_SOURCE)
if [ -z "${BASH_SOURCE[0]:-}" ]; then
    export PS4='+ [${BASH_SOURCE[0]:-user-data.sh}:${LINENO}]: '
fi

# ===========================================================================
# Configuration — override via environment variables
# ===========================================================================
PANEL_SUBDOMAIN="${PANEL_SUBDOMAIN:-panel.chadadigital.com}"
APP_ENV="${APP_ENV:-production}"
DB_CONNECTION="${DB_CONNECTION:-sqlite}"

# --- RDS / Docker stack database config ---
# When RDS_ENDPOINT is set, the local mysql container is disabled via an
# override and all DB_* point at RDS. Otherwise the bundled mysql runs.
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
DB_NAME="${DB_NAME:-chada_digital}"
DB_USER="${DB_USER:-chadaadmin}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_HOST="${DB_HOST:-${RDS_ENDPOINT:-mysql}}"
DB_PORT="${DB_PORT:-3306}"

PHP_VERSION="${PHP_VERSION:-8.5}"
PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
NGINX_PORT="${NGINX_PORT:-80}"
SSL_PORT="${SSL_PORT:-443}"
CHADA_DIGITAL_ENABLED="${CHADA_DIGITAL_ENABLED:-true}"
CHADA_DIGITAL_SUBDOMAIN="${CHADA_DIGITAL_SUBDOMAIN:-chadadigital.com}"
CHADA_DIGITAL_ROOT="${PROJECTS_DIR:-/opt/dstack-panel/projects}/chada.digital"
CHADA_DIGITAL_REPO="${CHADA_DIGITAL_REPO:-https://github.com/DGCodeIdeas/chada.digital.git}"
CHADA_DIGITAL_BRANCH="${CHADA_DIGITAL_BRANCH:-main}"

# Publish the web panel vhost? Default false — panel is managed via
# `php artisan dstack:tui`. The Laravel app, PHP-FPM dstack pool, SQLite DB,
# and TUI remain fully functional regardless of this flag.
PANEL_WEB_ENABLED="${PANEL_WEB_ENABLED:-false}"

# phpMyAdmin port (overridable)
PHPMYADMIN_PORT="${PHPMYADMIN_PORT:-8080}"

ROOT="/opt/dstack-panel"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yml"
ENV_FILE="${ROOT}/.env"
VHOSTS_DIR="${ROOT}/docker/vhosts"
SSL_DIR="${ROOT}/docker/ssl"
PROJECTS_DIR="${ROOT}/projects"
BACKUPS_DIR="${ROOT}/backups"
DB_PATH="${ROOT}/storage/database/panel.db"
DOCKER_ENV_FILE="${ROOT}/docker/.env"
COMPOSE_OVERRIDE="${ROOT}/docker/docker-compose.override.yml"
DOCKER_CONFIG_DIR="${ROOT}/docker/.docker-config"
REPO_URL="https://github.com/DGCodeIdeas/DStack.git"
LOG_FILE="/var/log/dstack-panel/bootstrap.log"

export DEBIAN_FRONTEND=noninteractive

# Ensure directories exist
mkdir -p /var/log/dstack-panel "${ROOT}"

# Colors for pretty output
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

log()    { echo -e "${BLUE}[INFO]${RESET} $*" | tee -a "${LOG_FILE}"; }
ok()     { echo -e "${GREEN}[ OK ]${RESET} $*" | tee -a "${LOG_FILE}"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*" | tee -a "${LOG_FILE}"; }
error()  { echo -e "${RED}[ERR ]${RESET} $*" | tee -a "${LOG_FILE}"; }
die()    { error "$*"; exit 1; }

# --- Idempotency helpers ---
pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
sock_exists() { [ -S "$1" ]; }

# ===========================================================================
# Preflight: OS check
# ===========================================================================
log "=== DStack Panel Production Bootstrap ==="
echo
log "Target: ${BOLD}${PANEL_SUBDOMAIN}${RESET}"
log "PHP:    ${PHP_VERSION}"
log "DB:     ${DB_CONNECTION}"
log "Root:   ${ROOT}"
echo

if [ ! -f /etc/os-release ]; then
    die "Cannot detect OS. This script targets Ubuntu 22.04/24.04."
fi

log "Operating system: $(grep '^PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"')"
log "Architecture:     $(uname -m)"
log "Kernel:           $(uname -r)"
echo

# ===========================================================================
# Phase 1: System Preparation
# ===========================================================================
echo
log "=== Phase: System Preparation ==="

log "Updating package index..."
apt-get update -qq
log "Upgrading existing packages..."
apt-get upgrade -y -qq
log "Installing base packages..."
apt-get install -y -qq curl git unzip ca-certificates gnupg lsb-release software-properties-common ufw fail2ban logrotate cron rsyslog
ok "Base packages installed."

# ===========================================================================
# Phase 2: Swap Space (safety for t3.small with 2 GB RAM)
# ===========================================================================
echo
log "=== Phase: Swap Configuration ==="

if [ -f /swapfile ] && swapon --show 2>/dev/null | grep -q /swapfile; then
    ok "Swap already active — skipping."
else
    if [ -f /swapfile ]; then
        log "Swap file exists but not active — activating..."
        swapon /swapfile
    else
        log "Creating 2 GB swap file..."
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    sysctl vm.swappiness=10
    grep -q '^vm.swappiness=' /etc/sysctl.conf 2>/dev/null && sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    ok "Swap activated: 2G at swappiness=10"
fi

# ===========================================================================
# Phase 3: Install PHP ${PHP_VERSION} and Extensions
# ===========================================================================
echo
log "=== Phase: PHP Install ==="

INSTALLED_PHP="none"
if command -v php >/dev/null 2>&1; then
    INSTALLED_PHP=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "none")
fi

if [ "${INSTALLED_PHP}" = "${PHP_VERSION}" ]; then
    ok "PHP ${PHP_VERSION} already installed."
else
    if [ "${INSTALLED_PHP}" != "none" ] && [ "${INSTALLED_PHP}" != "${PHP_VERSION}" ]; then
        log "Installed PHP ${INSTALLED_PHP} does not match required ${PHP_VERSION} — removing..."
        apt-get remove -y -qq php${INSTALLED_PHP}-fpm php${INSTALLED_PHP}-cli php${INSTALLED_PHP}-mysql php${INSTALLED_PHP}-sqlite3 php${INSTALLED_PHP}-pdo php${INSTALLED_PHP}-pdo-sqlite php${INSTALLED_PHP}-xml php${INSTALLED_PHP}-mbstring php${INSTALLED_PHP}-curl php${INSTALLED_PHP}-zip php${INSTALLED_PHP}-bcmath php${INSTALLED_PHP}-intl php${INSTALLED_PHP}-gd php${INSTALLED_PHP}-redis php${INSTALLED_PHP}-tokenizer php${INSTALLED_PHP}-fileinfo 2>/dev/null || true
    fi

    log "Setting up PHP repository (packages.sury.org)..."
    if grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        log "Removing legacy ondrej/php PPA..."
        add-apt-repository --remove ppa:ondrej/php -y 2>/dev/null || true
    fi
    if [ ! -f /usr/share/keyrings/deb.sury.org-php.gpg ]; then
        log "Adding Sury GPG key..."
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    fi
    if [ ! -f /etc/apt/sources.list.d/sury-php.list ]; then
        log "Adding Sury PHP repository..."
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
    fi
    apt-get update -qq
    ok "PHP repository configured."

    log "Installing PHP ${PHP_VERSION} and extensions..."
    if ! apt-get install -y -qq php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql php${PHP_VERSION}-sqlite3 php${PHP_VERSION}-pdo php${PHP_VERSION}-pdo-sqlite php${PHP_VERSION}-xml php${PHP_VERSION}-mbstring php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-gd php${PHP_VERSION}-redis php${PHP_VERSION}-tokenizer php${PHP_VERSION}-fileinfo 2>/dev/null; then
        warn "PHP ${PHP_VERSION} not found in Sury repo — detecting available version..."
        AVAILABLE_PHP=$(apt-cache search '^php[0-9.]*-fpm$' 2>/dev/null | sort -V | tail -1 | cut -d' ' -f1 | sed 's/-fpm//')
        if [ -n "${AVAILABLE_PHP}" ]; then
            PHP_VERSION="${AVAILABLE_PHP}"
            log "Using PHP version: ${PHP_VERSION}"
            apt-get install -y -qq php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql php${PHP_VERSION}-sqlite3 php${PHP_VERSION}-pdo php${PHP_VERSION}-pdo-sqlite php${PHP_VERSION}-xml php${PHP_VERSION}-mbstring php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-gd php${PHP_VERSION}-redis php${PHP_VERSION}-tokenizer php${PHP_VERSION}-fileinfo
            ok "PHP ${PHP_VERSION} installed (auto-detected)."
        else
            error "No PHP-FPM package found in any repository."
            exit 1
        fi
    else
        ok "PHP ${PHP_VERSION} installed."
    fi

    PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
    if ! sock_exists "${PHP_FPM_SOCK}"; then
        for sock in "/run/php/php${PHP_VERSION}-fpm.sock" "/var/run/php/php${PHP_VERSION}-fpm.sock" "/run/php-fpm${PHP_VERSION}.sock"; do
            if sock_exists "${sock}"; then
                PHP_FPM_SOCK="${sock}"
                break
            fi
        done
    fi
    log "PHP-FPM socket: ${PHP_FPM_SOCK}"
fi

# ===========================================================================
# Phase 4: Install Docker + Compose v2
# ===========================================================================
echo
log "=== Phase: Docker Install ==="

if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installed and enabled."
else
    ok "Docker already installed: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
    log "Installing Docker Compose plugin..."
    apt-get install -y -qq docker-compose-plugin
    ok "Docker Compose plugin installed."
else
    ok "Docker Compose already installed."
fi

if ! getent group docker | grep -qw www-data; then
    usermod -aG docker www-data
    log "Added www-data to docker group."
fi

# ===========================================================================
# Phase 5: Install Composer (global)
# ===========================================================================
echo
log "=== Phase: Composer Install ==="

if ! command -v composer &>/dev/null; then
    log "Downloading and installing Composer..."
    EXPECTED_CHECKSUM="$(curl -sL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]; then
        error "Composer installer checksum mismatch — aborting"
        rm -f composer-setup.php
        exit 1
    fi
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
    chmod +x /usr/local/bin/composer
    ok "Composer installed globally."
else
    ok "Composer already installed: $(composer --version 2>/dev/null | head -1)"
fi

# ===========================================================================
# Phase 6: Deploy Application Code
# ===========================================================================
echo
log "=== Phase: App Deploy ==="

log "Deploying application code to ${ROOT}..."
mkdir -p "${ROOT}"
chown -R ubuntu:www-data "${ROOT}"
chmod -R 775 "${ROOT}"

if [ ! -d "${ROOT}/.git" ]; then
    if [ -d "${ROOT}" ] && [ -n "$(ls -A "${ROOT}" 2>/dev/null)" ]; then
        BACKUP_DIR="${ROOT}.backup.$(date +%Y%m%d%H%M%S)"
        log "Directory ${ROOT} exists but is not a git repo — backing up to ${BACKUP_DIR}"
        mv "${ROOT}" "${BACKUP_DIR}"
        log "Backup complete: ${BACKUP_DIR}"
    fi
    log "Cloning repository: ${REPO_URL}"
    git clone "${REPO_URL}" "${ROOT}"
    git config --global --add safe.directory "${ROOT}" 2>/dev/null || true
else
    log "Repository already present — pulling latest"
    git config --global --add safe.directory "${ROOT}" 2>/dev/null || true
    cd "${ROOT}"
    git fetch origin --tags --quiet
    git pull origin main --quiet 2>/dev/null || git pull origin master --quiet 2>/dev/null || true
fi

cd "${ROOT}"
chown -R www-data:www-data "${ROOT}"
ok "Application code deployed."

# ===========================================================================
# Phase 7: Install PHP Dependencies (Production)
# ===========================================================================
echo
log "=== Phase: Dependencies Install ==="

log "Installing PHP dependencies (production, no-dev)..."
sudo -u www-data env HOME="${ROOT}" COMPOSER_HOME="${ROOT}/.composer" \
    composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${ROOT}" 2>&1 | tail -5 || warn "Composer install failed for panel"
ok "PHP dependencies installed."

# ===========================================================================
# Phase 8: Configure .env
# ===========================================================================
echo
log "=== Phase: Env Config ==="

[ -f "${ROOT}/.env" ] || cp "${ROOT}/.env.example" "${ROOT}/.env"
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
sed -i "s|^DSTACK_ROOT=.*|DSTACK_ROOT=${ROOT}|" "${ROOT}/.env"
sed -i "s|^DSTACK_DOCKER_COMPOSE_FILE=.*|DSTACK_DOCKER_COMPOSE_FILE=${COMPOSE_FILE}|" "${ROOT}/.env"
sed -i "s|^DSTACK_VHOSTS_DIR=.*|DSTACK_VHOSTS_DIR=${VHOSTS_DIR}|" "${ROOT}/.env"
sed -i "s|^DSTACK_SSL_DIR=.*|DSTACK_SSL_DIR=${SSL_DIR}|" "${ROOT}/.env"
sed -i "s|^DSTACK_PROJECTS_DIR=.*|DSTACK_PROJECTS_DIR=${PROJECTS_DIR}|" "${ROOT}/.env"
sed -i "s|^DSTACK_BACKUPS_DIR=.*|DSTACK_BACKUPS_DIR=${BACKUPS_DIR}|" "${ROOT}/.env"
mkdir -p "${VHOSTS_DIR}" "${SSL_DIR}" "${PROJECTS_DIR}" "${BACKUPS_DIR}"
mkdir -p "${ROOT}/storage/logs" "${ROOT}/storage/framework/cache" "${ROOT}/storage/framework/sessions" "${ROOT}/storage/framework/views" "${ROOT}/bootstrap/cache"
chown -R www-data:www-data "${ROOT}/storage" "${ROOT}/bootstrap/cache" "${VHOSTS_DIR}" "${SSL_DIR}" "${PROJECTS_DIR}" "${BACKUPS_DIR}" 2>/dev/null || true
chmod -R 775 "${ROOT}/storage" "${ROOT}/bootstrap/cache"
ok "Environment configured."

# --- Docker stack env (compose reads docker/.env, not the Laravel .env) ---
log "Writing docker stack env (${DOCKER_ENV_FILE})..."
mkdir -p "${ROOT}/docker"
cat > "${DOCKER_ENV_FILE}" <<EOF
COMPOSE_PROJECT_NAME=devstack
PHP_VERSION=${PHP_VERSION}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
TZ=UTC
EOF
chmod 640 "${DOCKER_ENV_FILE}"
chown www-data:www-data "${DOCKER_ENV_FILE}"
ok "Docker stack env written."

# --- Compose override: host nginx is the front door (see commit 4814cb4) ---
# The containerized nginx must NOT publish 80/443 — host nginx owns them and
# serves the panel via the PHP-FPM socket. phpMyAdmin is bound to localhost so
# only host nginx can proxy to it. In RDS mode the bundled mysql is disabled
# and phpMyAdmin points at the RDS endpoint.
log "Generating docker-compose.override.yml (host-nginx front door)..."

# Base override — always applied, both modes
cat > "${COMPOSE_OVERRIDE}" <<EOF
# Auto-generated by user-data.sh — do not edit by hand.
services:
  nginx:
    # Host nginx serves the panel; container nginx is redundant. Disable it.
    profiles: ["disabled"]
  phpmyadmin:
    ports:
      - "127.0.0.1:${PHPMYADMIN_PORT:-8080}:80"
EOF

if [ -n "${RDS_ENDPOINT}" ]; then
    log "RDS mode — disabling local mysql, pointing phpMyAdmin at RDS..."
    cat >> "${COMPOSE_OVERRIDE}" <<EOF
    depends_on: []
    environment:
      PMA_HOST: ${RDS_ENDPOINT}
      PMA_PORT: ${DB_PORT}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
  mysql:
    profiles: ["disabled"]
EOF
    ok "RDS override generated (nginx + mysql disabled)."
else
    ok "Local-mysql override generated (nginx disabled)."
fi

chown www-data:www-data "${COMPOSE_OVERRIDE}"

# ===========================================================================
# Phase 9: Application Key + Optimization
# ===========================================================================
echo
log "=== Phase: App Optimize ==="

log "Generating APP_KEY if missing..."
grep -q '^APP_KEY=base64:' "${ROOT}/.env" 2>/dev/null || sudo -u www-data env HOME="${ROOT}" php "${ROOT}/artisan" key:generate --force 2>/dev/null || true
log "Caching Laravel config, routes, views, and events..."
sudo -u www-data env HOME="${ROOT}" php "${ROOT}/artisan" config:cache 2>/dev/null || true
sudo -u www-data env HOME="${ROOT}" php "${ROOT}/artisan" route:cache 2>/dev/null || true
sudo -u www-data env HOME="${ROOT}" php "${ROOT}/artisan" view:cache 2>/dev/null || true
sudo -u www-data env HOME="${ROOT}" php "${ROOT}/artisan" event:cache 2>/dev/null || true
# Re-assert ownership AFTER cache files are written (cache commands run as www-data
# but earlier chown ensures the directory itself is owned by www-data)
chown -R www-data:www-data "${ROOT}/storage" "${ROOT}/bootstrap/cache" 2>/dev/null || true
ok "Laravel cache optimized."

# ===========================================================================
# Phase 10: Database Migrations
# ===========================================================================
echo
log "=== Phase: Database Migrate ==="

if [ "${DB_CONNECTION}" = "sqlite" ]; then
    log "Running database migrations (SQLite)..."
    sudo -u www-data env HOME="${ROOT}" php "${ROOT}/artisan" migrate --force 2>&1 | tail -3 || warn "Migration may have failed — check logs"
    chown -R www-data:www-data "${ROOT}/storage/database" 2>/dev/null || true
    ok "Migrations complete."
else
    log "Not using SQLite — skipping migrations."
fi

# ===========================================================================
# Phase 11: SSL Certificates (Let's Encrypt) — Certbot Setup
# ===========================================================================
echo
log "=== Phase: SSL Setup ==="

if ! command -v certbot >/dev/null 2>&1; then
    log "Installing Certbot..."
    apt-get install -y -qq certbot python3-certbot-nginx
    mkdir -p "${SSL_DIR}"
    chown -R www-data:www-data "${SSL_DIR}"
    systemctl enable --now nginx || true
    ok "Certbot installed."
else
    ok "Certbot already installed."
fi

# ===========================================================================
# Phase 12: PHP-FPM Tune + Pool Setup for 2 GB RAM (t3.small)
# ===========================================================================
echo
log "=== Phase: PHP-FPM Tune ==="

log "Tuning PHP-FPM for 2 GB RAM..."
FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

# Fix log file permissions so www-data can write to it
if [ -f /var/log/php${PHP_VERSION}-fpm.log ]; then
    chown www-data:www-data /var/log/php${PHP_VERSION}-fpm.log 2>/dev/null || true
    chmod 664 /var/log/php${PHP_VERSION}-fpm.log 2>/dev/null || true
fi

# Create dstack pool configuration alongside www pool
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
FPM_POOL_EOF
ok "PHP-FPM dstack pool configured."

# Tune www.conf parameters (idempotent — sed with no match is harmless)
if [ -f "${FPM_CONF}" ]; then
    sed -i 's/^pm = .*/pm = dynamic/' "${FPM_CONF}"
    sed -i 's/^pm.max_children = .*/pm.max_children = 6/' "${FPM_CONF}"
    sed -i 's/^pm.start_servers = .*/pm.start_servers = 3/' "${FPM_CONF}"
    sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "${FPM_CONF}"
    sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 4/' "${FPM_CONF}"
    sed -i 's/^pm.max_requests = .*/pm.max_requests = 1000/' "${FPM_CONF}"
else
    warn "PHP-FPM www.conf not found at ${FPM_CONF} — skipping"
fi

# Validate configuration before restarting
log "Validating PHP-FPM configuration..."
if ! php-fpm${PHP_VERSION} -t 2>&1 | tee -a "${LOG_FILE}"; then
    error "PHP-FPM configuration test failed — will not restart until fixed"
    warn "Check ${LOG_FILE} for details"
    FPM_TUNE_OK=false
else
    FPM_TUNE_OK=true
fi

if [ "${FPM_TUNE_OK}" = true ]; then
    log "Restarting PHP-FPM..."
    systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
    sleep 2
    if pgrep -x "php-fpm${PHP_VERSION}" > /dev/null; then
        ok "PHP-FPM ${PHP_VERSION} is running (pm=dynamic, max_children=6)"
    else
        error "PHP-FPM ${PHP_VERSION} is not running after restart"
        warn "Attempting recovery..."
        log "Re-validating PHP-FPM configuration..."
        if php-fpm${PHP_VERSION} -t 2>&1 | tee -a "${LOG_FILE}"; then
            systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
            sleep 2
            if pgrep -x "php-fpm${PHP_VERSION}" > /dev/null; then
                ok "PHP-FPM ${PHP_VERSION} recovered after re-restart"
            else
                warn "PHP-FPM ${PHP_VERSION} still not running — check journalctl -xeu php${PHP_VERSION}-fpm.service"
            fi
        else
            error "PHP-FPM config is invalid — cannot start without fixing configuration"
        fi
    fi
fi

# ===========================================================================
# Phase 13: Nginx + PHP-FPM (Direct PHP Serving)
# ===========================================================================
echo
log "=== Phase: Nginx Config ==="

if [ "${PANEL_WEB_ENABLED}" != "true" ]; then
    log "Panel web access disabled — removing panel vhost (TUI-only mode)..."
    rm -f "/etc/nginx/sites-enabled/${PANEL_SUBDOMAIN}.conf" 2>/dev/null || true
    rm -f "/etc/nginx/sites-available/${PANEL_SUBDOMAIN}.conf" 2>/dev/null || true
    ok "Panel vhost removed — manage via 'php artisan dstack:tui'."
else
    log "Configuring nginx + PHP-FPM (direct serving)..."
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    rm -f /etc/nginx/conf.d/upstreams.conf 2>/dev/null || true

    NGINX_CONF="/etc/nginx/sites-available/${PANEL_SUBDOMAIN}.conf"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > "${NGINX_CONF}" << NGINX_CONF_EOF
server {
    listen ${NGINX_PORT}; listen [::]:${NGINX_PORT};
    server_name ${PANEL_SUBDOMAIN}; return 301 https://\$host\$request_uri;
}
server {
    listen ${SSL_PORT} ssl http2; listen [::]:${SSL_PORT} ssl http2;
    server_name ${PANEL_SUBDOMAIN};
    root /opt/dstack-panel/public; index index.php index.html;
    client_max_body_size 64M;
    ssl_certificate     /etc/letsencrypt/live/${PANEL_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_SUBDOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on; ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    charset utf-8;
    location /assets/ { expires 1y; add_header Cache-Control "public, immutable"; access_log off; }
    location /favicon.ico { access_log off; log_not_found off; }
    location /robots.txt  { access_log off; log_not_found off; }
    location /well-known  { root /var/www/html; allow all; }
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-dstack.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 3600;
    }
    location ~ /\\. { deny all; access_log off; log_not_found off; }
    location ~* \\.(env|git|svn|htaccess|md|yml|yaml)$ { deny all; access_log off; log_not_found off; }
}
NGINX_CONF_EOF
    ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${PANEL_SUBDOMAIN}.conf"
    if nginx -t 2>/dev/null; then
        systemctl enable --now nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        ok "Nginx configured with PHP-FPM (direct serving)."
    else
        warn "Nginx config test failed — will retry after SSL certificate is obtained"
    fi
fi

# ===========================================================================
# Phase 14: SSL/TLS with Let's Encrypt
# ===========================================================================
echo
log "=== Phase: SSL Let's Encrypt ==="

if [ "${PANEL_WEB_ENABLED}" != "true" ]; then
    log "Panel web disabled — skipping panel SSL."
else
    SSL_CERT_READY=false
    if [ -f "/etc/letsencrypt/live/${PANEL_SUBDOMAIN}/fullchain.pem" ]; then
        ok "SSL certificate already exists for ${PANEL_SUBDOMAIN}."
        SSL_CERT_READY=true
    else
        log "Obtaining Let's Encrypt SSL certificate for ${PANEL_SUBDOMAIN}..."
        if certbot certonly --nginx --non-interactive --agree-tos --email "admin@${PANEL_SUBDOMAIN}" -d "${PANEL_SUBDOMAIN}" --rsa-key-size 4096 --force-renewal 2>/dev/null; then
            SSL_CERT_READY=true
            log "SSL certificate obtained for ${PANEL_SUBDOMAIN}"
            systemctl reload nginx 2>/dev/null || true
            (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
            log "Certbot auto-renewal cron job configured."
            ok "SSL certificate ready."
        else
            warn "SSL certificate could not be obtained — ensure DNS ${PANEL_SUBDOMAIN} points to this instance"
            warn "Run manually: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
        fi
    fi
fi

# ===========================================================================
# Phase 15: Firewall Hardening (UFW)
# ===========================================================================
echo
log "=== Phase: Firewall Config ==="

if ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "Firewall already active — ensuring rules."
else
    log "Configuring firewall (UFW)..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    echo "y" | ufw enable
    ufw limit 22/tcp 2>/dev/null || true
    ok "Firewall enabled: SSH(22), HTTP(80), HTTPS(443) allowed"
fi

# ===========================================================================
# Phase 16: Fail2ban for SSH Protection
# ===========================================================================
echo
log "=== Phase: Fail2ban Config ==="

log "Configuring Fail2ban..."
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
ok "Fail2ban enabled with SSH brute-force protection (3 attempts / 1 hour ban)"

# ===========================================================================
# Phase 17: Log Rotation
# ===========================================================================
echo
log "=== Phase: Log Rotation ==="

log "Configuring log rotation..."
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
ok "Log rotation configured (14 days for app logs, 7 days for supervisor)"

# ===========================================================================
# Phase 18: Cron Jobs for Laravel Scheduler
# ===========================================================================
echo
log "=== Phase: Cron Config ==="

log "Configuring Laravel scheduler cron..."
(crontab -u www-data -l 2>/dev/null | grep -v 'artisan schedule' || true; echo "* * * * * cd /opt/dstack-panel && php artisan schedule:run >> /opt/dstack-panel/storage/logs/scheduler.log 2>&1") | crontab -u www-data - 2>/dev/null || warn "Cron configuration may have failed"
ok "Laravel scheduler cron configured for www-data user"

# ===========================================================================
# Phase 19: Start Application Services
# ===========================================================================
echo
log "=== Phase: Services Start ==="

log "Starting application services..."
if [ -f "${COMPOSE_FILE}" ]; then
    cd "${ROOT}"

    # www-data's $HOME is /var/www (root-owned) → Docker CLI cannot create
    # ~/.docker. Provide a writable, dedicated config dir.
    mkdir -p "${DOCKER_CONFIG_DIR}"
    chown -R www-data:www-data "${DOCKER_CONFIG_DIR}"

    # Explicitly pass both compose files so the override is loaded
    # regardless of CWD.
    COMPOSE_FILES=(-f "${COMPOSE_FILE}")
    [ -f "${COMPOSE_OVERRIDE}" ] && COMPOSE_FILES+=(-f "${COMPOSE_OVERRIDE}")

    # In RDS mode, remove any previously-started local mysql from a prior
    # non-RDS run so --remove-orphans doesn't leave a zombie container.
    if [ -n "${RDS_ENDPOINT}" ]; then
        sudo -u www-data env DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" \
            docker compose --env-file "${DOCKER_ENV_FILE}" "${COMPOSE_FILES[@]}" \
            rm -sf mysql 2>/dev/null || true
    fi

    if COMPOSE_OUTPUT=$(sudo -u www-data \
            env HOME="${ROOT}/docker" DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" \
            docker compose --env-file "${DOCKER_ENV_FILE}" "${COMPOSE_FILES[@]}" \
            up -d --build --remove-orphans 2>&1); then
        RUNNING=$(sudo -u www-data env DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" \
            docker compose --env-file "${DOCKER_ENV_FILE}" "${COMPOSE_FILES[@]}" \
            ps --status running -q 2>/dev/null | wc -l)
        if [ "${RUNNING}" -gt 0 ]; then
            ok "Services started (${RUNNING} containers running)."
        else
            warn "Compose ran but 0 containers are running. Output:"
            warn "${COMPOSE_OUTPUT}"
        fi
    else
        warn "Docker Compose stack start failed — ${COMPOSE_OUTPUT}"
    fi
fi

# ===========================================================================
# Phase 20: Health Check Verification
# ===========================================================================
echo
log "=== Phase: Health Check ==="
log "Running health verification..."
sleep 3

if pgrep -x "php-fpm${PHP_VERSION}" > /dev/null; then
    ok "PHP-FPM ${PHP_VERSION}: running"
else
    warn "PHP-FPM ${PHP_VERSION}: not running — attempting recovery"
    if [ -f /var/log/php${PHP_VERSION}-fpm.log ]; then
        chown www-data:www-data /var/log/php${PHP_VERSION}-fpm.log 2>/dev/null || true
        chmod 664 /var/log/php${PHP_VERSION}-fpm.log 2>/dev/null || true
    fi
    if php-fpm${PHP_VERSION} -t 2>/dev/null; then
        systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
        sleep 2
    fi
    if pgrep -x "php-fpm${PHP_VERSION}" > /dev/null; then
        ok "PHP-FPM ${PHP_VERSION}: recovered successfully"
    else
        warn "PHP-FPM ${PHP_VERSION}: failed to recover — check journalctl -xeu php${PHP_VERSION}-fpm.service"
    fi
fi

if systemctl is-active --quiet nginx; then
    ok "Nginx: running"
else
    warn "Nginx: not running — attempting restart"
    systemctl restart nginx 2>/dev/null || true
fi

if docker info > /dev/null 2>&1; then
    ok "Docker: running"
else
    warn "Docker: not running — attempting restart"
    systemctl restart docker 2>/dev/null || true
fi

if [ "${DB_CONNECTION}" = "sqlite" ] && [ -f "${DB_PATH}" ]; then
    ok "SQLite database: ready"
fi

# ===========================================================================
# Phase 21: Chada.digital App Deployment
# ===========================================================================
if [ "${CHADA_DIGITAL_ENABLED}" = "true" ]; then
    echo
    log "=== Phase: Chada.digital Deploy ==="
    log "Deploying chada.digital application..."

    mkdir -p "${CHADA_DIGITAL_ROOT}"
    chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}"

    if [ ! -d "${CHADA_DIGITAL_ROOT}/.git" ]; then
        if [ -d "${CHADA_DIGITAL_ROOT}" ] && [ -n "$(ls -A "${CHADA_DIGITAL_ROOT}" 2>/dev/null)" ]; then
            CHADA_BACKUP_DIR="${CHADA_DIGITAL_ROOT}.backup.$(date +%Y%m%d%H%M%S)"
            log "Directory ${CHADA_DIGITAL_ROOT} exists but is not a git repo — backing up to ${CHADA_BACKUP_DIR}"
            mv "${CHADA_DIGITAL_ROOT}" "${CHADA_BACKUP_DIR}"
            log "Backup complete: ${CHADA_BACKUP_DIR}"
        fi
        log "Cloning chada.digital repository: ${CHADA_DIGITAL_REPO}"
        git clone "${CHADA_DIGITAL_REPO}" "${CHADA_DIGITAL_ROOT}" 2>/dev/null || warn "Git clone failed for chada.digital"
    else
        log "Chada.digital repo already present — pulling latest"
        git config --global --add safe.directory "${CHADA_DIGITAL_ROOT}" 2>/dev/null || true
        cd "${CHADA_DIGITAL_ROOT}"
        git fetch origin --tags --quiet 2>/dev/null || true
        git pull origin "${CHADA_DIGITAL_BRANCH}" --quiet 2>/dev/null || git pull origin master --quiet 2>/dev/null || git pull origin main --quiet 2>/dev/null || true
    fi

    if [ -d "${CHADA_DIGITAL_ROOT}" ]; then
        cd "${CHADA_DIGITAL_ROOT}"
        chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}"

        if [ -f "${CHADA_DIGITAL_ROOT}/composer.json" ]; then
            log "Installing chada.digital PHP dependencies..."
            sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" COMPOSER_HOME="${CHADA_DIGITAL_ROOT}/.composer" \
                composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${CHADA_DIGITAL_ROOT}" 2>&1 | tail -5 || warn "Composer install failed for chada.digital"
        fi

        if [ -f "${CHADA_DIGITAL_ROOT}/.env" ]; then
            grep -q '^APP_KEY=base64:' "${CHADA_DIGITAL_ROOT}/.env" 2>/dev/null || sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" php "${CHADA_DIGITAL_ROOT}/artisan" key:generate --force 2>/dev/null || true
            sed -i "s|^APP_ENV=.*|APP_ENV=production|" "${CHADA_DIGITAL_ROOT}/.env"
            sed -i "s|^APP_URL=.*|APP_URL=https://${CHADA_DIGITAL_SUBDOMAIN}|" "${CHADA_DIGITAL_ROOT}/.env"
            sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${CHADA_DIGITAL_ROOT}/.env"
            sed -i "s|^LOG_LEVEL=.*|LOG_LEVEL=warning|" "${CHADA_DIGITAL_ROOT}/.env"
        else
            cp "${CHADA_DIGITAL_ROOT}/.env.example" "${CHADA_DIGITAL_ROOT}/.env" 2>/dev/null || true
            sed -i "s|^APP_ENV=.*|APP_ENV=production|" "${CHADA_DIGITAL_ROOT}/.env"
            sed -i "s|^APP_URL=.*|APP_URL=https://${CHADA_DIGITAL_SUBDOMAIN}|" "${CHADA_DIGITAL_ROOT}/.env"
            sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${CHADA_DIGITAL_ROOT}/.env"
        fi

        mkdir -p "${CHADA_DIGITAL_ROOT}/storage/logs" "${CHADA_DIGITAL_ROOT}/storage/framework/cache" "${CHADA_DIGITAL_ROOT}/storage/framework/sessions" "${CHADA_DIGITAL_ROOT}/storage/framework/views" "${CHADA_DIGITAL_ROOT}/bootstrap/cache"
chmod -R 775 "${CHADA_DIGITAL_ROOT}/storage" "${CHADA_DIGITAL_ROOT}/bootstrap/cache"

sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" php "${CHADA_DIGITAL_ROOT}/artisan" config:cache 2>/dev/null || true
sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" php "${CHADA_DIGITAL_ROOT}/artisan" route:cache 2>/dev/null || true
sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" php "${CHADA_DIGITAL_ROOT}/artisan" view:cache 2>/dev/null || true
sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" php "${CHADA_DIGITAL_ROOT}/artisan" event:cache 2>/dev/null || true

# Re-assert ownership AFTER cache commands (critical: chown before cache
# leaves cache files root-owned, breaking PHP-FPM/www-data writes)
chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}/storage" "${CHADA_DIGITAL_ROOT}/bootstrap/cache" 2>/dev/null || true

if [ "${DB_CONNECTION}" = "sqlite" ]; then
    CHADA_DB_PATH="${CHADA_DIGITAL_ROOT}/storage/database/chada.db"
    mkdir -p "${CHADA_DIGITAL_ROOT}/storage/database"
    touch "${CHADA_DB_PATH}"
    chown www-data:www-data "${CHADA_DB_PATH}"
    sudo -u www-data env HOME="${CHADA_DIGITAL_ROOT}" php "${CHADA_DIGITAL_ROOT}/artisan" migrate --force 2>/dev/null || warn "Chada.digital migrations may have failed"
fi

        CHADA_NGINX_CONF="/etc/nginx/sites-available/${CHADA_DIGITAL_SUBDOMAIN}.conf"
        cat > "${CHADA_NGINX_CONF}" << CHADA_NGINX_EOF
server {
    listen ${NGINX_PORT}; listen [::]:${NGINX_PORT};
    server_name ${CHADA_DIGITAL_SUBDOMAIN}; return 301 https://\$host\$request_uri;
}
server {
    listen ${SSL_PORT} ssl http2; listen [::]:${SSL_PORT} ssl http2;
    server_name ${CHADA_DIGITAL_SUBDOMAIN};
    root ${CHADA_DIGITAL_ROOT}/public; index index.php index.html;
    client_max_body_size 64M;
    ssl_certificate     /etc/letsencrypt/live/${CHADA_DIGITAL_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CHADA_DIGITAL_SUBDOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on; ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    charset utf-8;
    location /assets/ { expires 1y; add_header Cache-Control "public, immutable"; access_log off; }
    location /favicon.ico { access_log off; log_not_found off; }
    location /robots.txt  { access_log off; log_not_found off; }
    location /well-known  { root /var/www/html; allow all; }
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 3600;
    }
    location ~ /\\. { deny all; access_log off; log_not_found off; }
    location ~* \\.(env|git|svn|htaccess|md|yml|yaml)$ { deny all; access_log off; log_not_found off; }
}
CHADA_NGINX_EOF
        ln -sf "${CHADA_NGINX_CONF}" "/etc/nginx/sites-enabled/${CHADA_DIGITAL_SUBDOMAIN}.conf"
        if nginx -t 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
            ok "Chada.digital nginx vhost configured for ${CHADA_DIGITAL_SUBDOMAIN}"
        else
            warn "Chada.digital nginx config test failed — will retry after SSL is obtained"
        fi

        if [ -f "/etc/letsencrypt/live/${CHADA_DIGITAL_SUBDOMAIN}/fullchain.pem" ]; then
            ok "Chada.digital SSL certificate already exists."
        else
            if certbot certonly --nginx --non-interactive --agree-tos --email "admin@${CHADA_DIGITAL_SUBDOMAIN}" -d "${CHADA_DIGITAL_SUBDOMAIN}" --rsa-key-size 4096 --force-renewal 2>/dev/null; then
                log "SSL certificate obtained for ${CHADA_DIGITAL_SUBDOMAIN}"
                systemctl reload nginx 2>/dev/null || true
                ok "Chada.digital SSL certificate ready."
            else
                warn "SSL certificate could not be obtained for ${CHADA_DIGITAL_SUBDOMAIN}"
            fi
        fi

        ok "Chada.digital app deployment complete"
    else
        warn "Chada.digital repo not available — skipping deployment"
    fi
fi

# ===========================================================================
# Final Output
# ===========================================================================
log "=== DStack Panel Bootstrap Complete ==="
echo
log "========================================="
log " DStack Panel bootstrap complete"
log "========================================="
log "  Application root: ${ROOT}"
if [ "${PANEL_WEB_ENABLED}" = "true" ]; then
    log "  Panel URL: https://${PANEL_SUBDOMAIN}"
else
    log "  Panel access: TUI only — run: sudo -u www-data php artisan dstack:tui"
fi
log "  PHP version: ${PHP_VERSION}"
log "  Database: ${DB_CONNECTION}"
log "  SSL ready: ${SSL_CERT_READY:-false}"
log "  Docker Compose stack: $(sudo -u www-data env DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" docker compose --env-file "${DOCKER_ENV_FILE}" -f "${COMPOSE_FILE}" -f "${COMPOSE_OVERRIDE}" ps --status running -q 2>/dev/null | wc -l) running"
log "  Chada.digital URL: https://${CHADA_DIGITAL_SUBDOMAIN}"
log ""
log " Next steps:"
log "  1. Update DNS ${PANEL_SUBDOMAIN} → this instance's public IP"
if [ "${CHADA_DIGITAL_ENABLED}" = "true" ]; then
    log "  2. Update DNS ${CHADA_DIGITAL_SUBDOMAIN} → this instance's public IP"
fi
log "  3. If SSL failed, run: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
log "  4. Check logs: tail -f ${ROOT}/storage/logs/laravel.log"
log "========================================="
