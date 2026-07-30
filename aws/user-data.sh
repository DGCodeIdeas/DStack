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
# Idempotent: safe to re-run. Progress tracked via:
#   /var/log/dstack-panel/checkpoints — phase completion log (outside ROOT so it survives re-clone)
#   /var/log/dstack-panel/deploy-status — current phase (JSON, read by API, survives re-clone)
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
PHP_VERSION="${PHP_VERSION:-8.5}"
NGINX_PORT="${NGINX_PORT:-80}"
SSL_PORT="${SSL_PORT:-443}"
CHADA_DIGITAL_ENABLED="${CHADA_DIGITAL_ENABLED:-true}"
CHADA_DIGITAL_SUBDOMAIN="${CHADA_DIGITAL_SUBDOMAIN:-chadadigital.com}"
CHADA_DIGITAL_ROOT="${PROJECTS_DIR:-/opt/dstack-panel/projects}/chada.digital"
CHADA_DIGITAL_REPO="${CHADA_DIGITAL_REPO:-https://github.com/DGCodeIdeas/chada.digital.git}"
CHADA_DIGITAL_BRANCH="${CHADA_DIGITAL_BRANCH:-main}"

ROOT="/opt/dstack-panel"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yml"
ENV_FILE="${ROOT}/.env"
VHOSTS_DIR="${ROOT}/docker/vhosts"
SSL_DIR="${ROOT}/docker/ssl"
PROJECTS_DIR="${ROOT}/projects"
BACKUPS_DIR="${ROOT}/backups"
DB_PATH="${ROOT}/storage/database/panel.db"
REPO_URL="https://github.com/DGCodeIdeas/DStack.git"
CHECKPOINT_FILE="/var/log/dstack-panel/checkpoints"
DEPLOY_STATUS_FILE="/var/log/dstack-panel/deploy-status"

export DEBIAN_FRONTEND=noninteractive

# Ensure directories exist for checkpoint/status files
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

log()    { echo -e "${BLUE}[INFO]${RESET} $*" | tee -a "${CHECKPOINT_FILE}.log"; }
ok()     { echo -e "${GREEN}[ OK ]${RESET} $*" | tee -a "${CHECKPOINT_FILE}.log"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*" | tee -a "${CHECKPOINT_FILE}.log"; }
error()  { echo -e "${RED}[ERR ]${RESET} $*" | tee -a "${CHECKPOINT_FILE}.log"; }
die()    { error "$*"; exit 1; }

# --- Progress tracking ---
record_checkpoint() {
    local level="$1" message="$2"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "${ROOT}" "$(dirname "${CHECKPOINT_FILE}")" 2>/dev/null || true
    echo "${ts}|${level}|${CURRENT_PHASE:-unknown}|${message}" >> "${CHECKPOINT_FILE}"
    echo "{\"timestamp\":\"${ts}\",\"level\":\"${level}\",\"phase\":\"${CURRENT_PHASE:-unknown}\",\"message\":\"${message}\"}" > "${DEPLOY_STATUS_FILE}"
}

set_current_phase() {
    CURRENT_PHASE="$1"
    record_checkpoint "PHASE_START" "Starting $1"
    echo
    log "=== Phase: ${BOLD}${CURRENT_PHASE}${RESET} ==="
}

mark_phase_done() {
    echo "DONE:$1" >> "${CHECKPOINT_FILE}"
    record_checkpoint "PHASE_DONE" "Completed $1"
}

check_phase_done() {
    grep -q "DONE:$1" "${CHECKPOINT_FILE}" 2>/dev/null
}

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
set_current_phase "system-preparation"

if ! check_phase_done "system-preparation"; then
    log "Updating package index..."
    apt-get update -qq
    log "Upgrading existing packages..."
    apt-get upgrade -y -qq
    log "Installing base packages..."
    apt-get install -y -qq curl git unzip ca-certificates gnupg lsb-release software-properties-common ufw fail2ban logrotate cron rsyslog
    ok "Base packages installed."
    mark_phase_done "system-preparation"
else
    ok "Phase 1 already complete — skipping"
fi

# ===========================================================================
# Phase 2: Swap Space (safety for t3.small with 2 GB RAM)
# ===========================================================================
set_current_phase "swap-configuration"

if ! check_phase_done "swap-configuration"; then
    if [ ! -f /swapfile ]; then
        log "Creating 2 GB swap file..."
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl vm.swappiness=10
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
        ok "Swap activated: 2G at swappiness=10"
    else
        ok "Swap file already exists — skipping"
    fi
    mark_phase_done "swap-configuration"
else
    ok "Phase 2 already complete — skipping"
fi

# ===========================================================================
# Phase 3: Install PHP ${PHP_VERSION} and Extensions
# ===========================================================================
set_current_phase "php-install"

# Check if installed PHP version matches required version
INSTALLED_PHP=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "none")
if [ "${INSTALLED_PHP}" != "${PHP_VERSION}" ]; then
    log "Installed PHP ${INSTALLED_PHP} does not match required ${PHP_VERSION} — resetting checkpoint"
    sed -i '/DONE:php-install/d' "${CHECKPOINT_FILE}" 2>/dev/null || true
fi

if ! check_phase_done "php-install"; then
    log "Setting up PHP repository (packages.sury.org)..."
    # Remove legacy PPA if present
    if grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        log "Removing legacy ondrej/php PPA..."
        add-apt-repository --remove ppa:ondrej/php -y 2>/dev/null || true
    fi
    # Add Sury GPG key and repository (required for Ubuntu 26.04+)
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
        # Detect available PHP version
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
    mark_phase_done "php-install"
else
    ok "Phase 3 already complete — skipping"
fi

# ===========================================================================
# Phase 4: Install Docker + Compose v2
# ===========================================================================
set_current_phase "docker-install"

if ! check_phase_done "docker-install"; then
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
    mark_phase_done "docker-install"
else
    ok "Phase 4 already complete — skipping"
fi

# ===========================================================================
# Phase 5: Install Composer (global)
# ===========================================================================
set_current_phase "composer-install"

if ! check_phase_done "composer-install"; then
    if ! command -v composer &>/dev/null; then
        log "Downloading and installing Composer..."
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
        ok "Composer installed globally."
    else
        ok "Composer already installed: $(composer --version 2>/dev/null | head -1)"
    fi
    mark_phase_done "composer-install"
else
    ok "Phase 5 already complete — skipping"
fi

# ===========================================================================
# Phase 6: Deploy Application Code
# ===========================================================================
set_current_phase "app-deploy"

if ! check_phase_done "app-deploy"; then
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
        git pull origin main --quiet || git pull origin master --quiet || true
    fi
    cd "${ROOT}"
    chown -R www-data:www-data "${ROOT}"
    ok "Application code deployed."
    mark_phase_done "app-deploy"
else
    log "Phase 6 already complete — pulling latest"
    git config --global --add safe.directory "${ROOT}" 2>/dev/null || true
    cd "${ROOT}"
    git fetch origin --tags --quiet
    git pull origin main --quiet || git pull origin master --quiet || true
    chown -R www-data:www-data "${ROOT}"
fi

# ===========================================================================
# Phase 7: Install PHP Dependencies (Production)
# ===========================================================================
set_current_phase "dependencies-install"

if ! check_phase_done "dependencies-install"; then
    log "Installing PHP dependencies (production, no-dev)..."
    composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${ROOT}" 2>&1 | tail -5
    ok "PHP dependencies installed."
    mark_phase_done "dependencies-install"
else
    ok "Phase 7 already complete — skipping"
fi

# ===========================================================================
# Phase 8: Configure .env
# ===========================================================================
set_current_phase "env-config"

if ! check_phase_done "env-config"; then
    log "Configuring environment..."
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
    mark_phase_done "env-config"
else
    ok "Phase 8 already complete — skipping"
fi

# ===========================================================================
# Phase 9: Application Key + Optimization
# ===========================================================================
set_current_phase "app-optimize"

if ! check_phase_done "app-optimize"; then
    log "Generating APP_KEY if missing..."
    grep -q '^APP_KEY=base64:' "${ROOT}/.env" 2>/dev/null || php "${ROOT}/artisan" key:generate --force
    log "Caching Laravel config, routes, views, and events..."
    php "${ROOT}/artisan" config:cache --force
    php "${ROOT}/artisan" route:cache --force
    php "${ROOT}/artisan" view:cache --force
    php "${ROOT}/artisan" event:cache --force
    ok "Laravel cache optimized."
    mark_phase_done "app-optimize"
else
    ok "Phase 9 already complete — skipping"
fi

# ===========================================================================
# Phase 10: Database Migrations
# ===========================================================================
set_current_phase "database-migrate"

if ! check_phase_done "database-migrate"; then
    if [ "${DB_CONNECTION}" = "sqlite" ] && [ -f "${DB_PATH}" ]; then
        log "Running database migrations (SQLite)..."
        php "${ROOT}/artisan" migrate --force 2>&1 | tail -3 || warn "Migration may have failed — check logs"
        ok "Migrations complete."
    else
        log "Not using SQLite — skipping migrations."
    fi
    mark_phase_done "database-migrate"
else
    ok "Phase 10 already complete — skipping"
fi

# ===========================================================================
# Phase 11: SSL Certificates (Let's Encrypt)
# ===========================================================================
set_current_phase "ssl-setup"

if ! check_phase_done "ssl-setup"; then
    log "Installing Certbot..."
    apt-get install -y -qq certbot python3-certbot-nginx
    mkdir -p "${SSL_DIR}"
    chown -R www-data:www-data "${SSL_DIR}"
    systemctl enable --now nginx || true
    SSL_CERT_READY=false
    mark_phase_done "ssl-setup"
else
    ok "Phase 11 already complete — skipping"
fi

# ===========================================================================
# Phase 12: PHP-FPM Tuning for 2 GB RAM (t3.small)
# ===========================================================================
set_current_phase "php-fpm-tune"

if ! check_phase_done "php-fpm-tune"; then
    log "Tuning PHP-FPM for 2 GB RAM..."
    FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    if [ -f "${FPM_CONF}" ]; then
        sed -i 's/^pm = .*/pm = dynamic/' "${FPM_CONF}"
        sed -i 's/^pm.max_children = .*/pm.max_children = 6/' "${FPM_CONF}"
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 3/' "${FPM_CONF}"
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "${FPM_CONF}"
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 4/' "${FPM_CONF}"
        sed -i 's/^pm.max_requests = .*/pm.max_requests = 1000/' "${FPM_CONF}"
        systemctl restart "php${PHP_VERSION}-fpm"
        ok "PHP-FPM tuned: pm=dynamic, max_children=6"
    else
        warn "PHP-FPM config not found at ${FPM_CONF} — skipping tuning"
    fi
    mark_phase_done "php-fpm-tune"
else
    ok "Phase 12 already complete — skipping"
fi

# ===========================================================================
# Phase 13: Nginx + PHP-FPM (Direct PHP Serving)
# ===========================================================================
set_current_phase "nginx-config"

if ! check_phase_done "nginx-config"; then
    log "Configuring nginx + PHP-FPM (direct serving)..."
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    rm -f /etc/nginx/conf.d/upstreams.conf 2>/dev/null || true

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
    sed -i 's/^pm = .*/pm = off/' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf 2>/dev/null || true

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
    mark_phase_done "nginx-config"
else
    ok "Phase 13 already complete — skipping"
fi

# ===========================================================================
# Phase 14: SSL/TLS with Let's Encrypt
# ===========================================================================
set_current_phase "ssl-letsencrypt"

if ! check_phase_done "ssl-letsencrypt"; then
    log "Obtaining Let's Encrypt SSL certificate for ${PANEL_SUBDOMAIN}..."
    SSL_CERT_READY=false
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
    mark_phase_done "ssl-letsencrypt"
else
    ok "Phase 14 already complete — skipping"
fi

# ===========================================================================
# Phase 15: Firewall Hardening (UFW)
# ===========================================================================
set_current_phase "firewall-config"

if ! check_phase_done "firewall-config"; then
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
    mark_phase_done "firewall-config"
else
    ok "Phase 15 already complete — skipping"
fi

# ===========================================================================
# Phase 16: Fail2ban for SSH Protection
# ===========================================================================
set_current_phase "fail2ban-config"

if ! check_phase_done "fail2ban-config"; then
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
    mark_phase_done "fail2ban-config"
else
    ok "Phase 16 already complete — skipping"
fi

# ===========================================================================
# Phase 17: Log Rotation
# ===========================================================================
set_current_phase "log-rotation"

if ! check_phase_done "log-rotation"; then
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
    mark_phase_done "log-rotation"
else
    ok "Phase 17 already complete — skipping"
fi

# ===========================================================================
# Phase 18: Cron Jobs for Laravel Scheduler
# ===========================================================================
set_current_phase "cron-config"

if ! check_phase_done "cron-config"; then
    log "Configuring Laravel scheduler cron..."
    (crontab -u www-data -l 2>/dev/null | grep -v 'artisan schedule'; echo "* * * * * cd /opt/dstack-panel && php artisan schedule:run >> /opt/dstack-panel/storage/logs/scheduler.log 2>&1") | crontab -u www-data -
    ok "Laravel scheduler cron configured for www-data user"
    mark_phase_done "cron-config"
else
    ok "Phase 18 already complete — skipping"
fi

# ===========================================================================
# Phase 19: Start Application Services
# ===========================================================================
set_current_phase "services-start"

if ! check_phase_done "services-start"; then
    log "Starting application services..."
    if [ -f "${COMPOSE_FILE}" ]; then
        cd "${ROOT}"
        sudo -u www-data docker compose up -d --remove-orphans 2>/dev/null || warn "Docker Compose stack start failed — check ${COMPOSE_FILE}"
    fi
    ok "Services started."
    mark_phase_done "services-start"
else
    ok "Phase 19 already complete — skipping"
fi

# ===========================================================================
# Phase 20: Health Check Verification
# ===========================================================================
set_current_phase "health-check"
log "Running health verification..."
sleep 3

if pgrep -x "php-fpm${PHP_VERSION}" > /dev/null; then
    ok "PHP-FPM ${PHP_VERSION}: running"
else
    warn "PHP-FPM ${PHP_VERSION}: not running — attempting restart"
    systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
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
    set_current_phase "chada-digital-deploy"
    log "Deploying chada.digital application..."

    if ! check_phase_done "chada-digital-deploy"; then
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
            git fetch origin --tags --quiet
            git pull origin "${CHADA_DIGITAL_BRANCH}" --quiet || true
        fi

        if [ -d "${CHADA_DIGITAL_ROOT}" ]; then
            cd "${CHADA_DIGITAL_ROOT}"
            chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}"

            if [ -f "${CHADA_DIGITAL_ROOT}/composer.json" ]; then
                log "Installing chada.digital PHP dependencies..."
                composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${CHADA_DIGITAL_ROOT}" 2>&1 | tail -5 || warn "Composer install failed for chada.digital"
            fi

            if [ -f "${CHADA_DIGITAL_ROOT}/.env" ]; then
                grep -q '^APP_KEY=base64:' "${CHADA_DIGITAL_ROOT}/.env" 2>/dev/null || php "${CHADA_DIGITAL_ROOT}/artisan" key:generate --force 2>/dev/null || true
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
            chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}/storage" "${CHADA_DIGITAL_ROOT}/bootstrap/cache"
            chmod -R 775 "${CHADA_DIGITAL_ROOT}/storage" "${CHADA_DIGITAL_ROOT}/bootstrap/cache"

            php "${CHADA_DIGITAL_ROOT}/artisan" config:cache --force 2>/dev/null || true
            php "${CHADA_DIGITAL_ROOT}/artisan" route:cache --force 2>/dev/null || true
            php "${CHADA_DIGITAL_ROOT}/artisan" view:cache --force 2>/dev/null || true
            php "${CHADA_DIGITAL_ROOT}/artisan" event:cache --force 2>/dev/null || true

            if [ "${DB_CONNECTION}" = "sqlite" ]; then
                CHADA_DB_PATH="${CHADA_DIGITAL_ROOT}/storage/database/chada.db"
                mkdir -p "${CHADA_DIGITAL_ROOT}/storage/database"
                touch "${CHADA_DB_PATH}"
                chown www-data:www-data "${CHADA_DB_PATH}"
                php "${CHADA_DIGITAL_ROOT}/artisan" migrate --force 2>/dev/null || warn "Chada.digital migrations may have failed"
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

            if certbot certonly --nginx --non-interactive --agree-tos --email "admin@${CHADA_DIGITAL_SUBDOMAIN}" -d "${CHADA_DIGITAL_SUBDOMAIN}" --rsa-key-size 4096 --force-renewal 2>/dev/null; then
                log "SSL certificate obtained for ${CHADA_DIGITAL_SUBDOMAIN}"
                systemctl reload nginx 2>/dev/null || true
                ok "Chada.digital SSL certificate ready."
            else
                warn "SSL certificate could not be obtained for ${CHADA_DIGITAL_SUBDOMAIN}"
            fi

            ok "Chada.digital app deployment complete"
        else
            warn "Chada.digital repo not available — skipping deployment"
        fi
        mark_phase_done "chada-digital-deploy"
    else
        ok "Phase 21 already complete — skipping"
    fi
fi

# ===========================================================================
# Final Output
# ===========================================================================
set_current_phase "complete"
echo
log "========================================="
log " DStack Panel bootstrap complete"
log "========================================="
log "  Application root: ${ROOT}"
log "  Panel URL: https://${PANEL_SUBDOMAIN}"
log "  PHP version: ${PHP_VERSION}"
log "  Database: ${DB_CONNECTION}"
log "  SSL ready: ${SSL_CERT_READY:-false}"
log "  Docker Compose stack: $(docker compose -f ${COMPOSE_FILE} ps 2>/dev/null | grep -c running || echo 0) running"
if [ "${CHADA_DIGITAL_ENABLED}" = "true" ]; then
    log "  Chada.digital URL: https://${CHADA_DIGITAL_SUBDOMAIN}"
fi
log ""
log " Next steps:"
log "  1. Update DNS ${PANEL_SUBDOMAIN} → this instance's public IP"
if [ "${CHADA_DIGITAL_ENABLED}" = "true" ]; then
    log "  2. Update DNS ${CHADA_DIGITAL_SUBDOMAIN} → this instance's public IP"
fi
log "  3. If SSL failed, run: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
log "  4. Check logs: tail -f ${ROOT}/storage/logs/laravel.log"
log "  5. Check progress: cat ${DEPLOY_STATUS_FILE}"
log "========================================="

echo "{\"phase\":\"complete\",\"status\":\"done\",\"finished_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" > "${DEPLOY_STATUS_FILE}"
