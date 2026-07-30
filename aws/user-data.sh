#!/bin/bash
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
PHP_VERSION="${PHP_VERSION:-8.2}"
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
CHECKPOINT_FILE="${ROOT}/.checkpoints"
DEPLOY_STATUS_FILE="${ROOT}/.deploy-status"

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; record_checkpoint "INFO" "$*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; record_checkpoint "WARN" "$*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; record_checkpoint "ERROR" "$*"; }

record_checkpoint() {
    local level="$1" message="$2"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "${ts}|${level}|${CURRENT_PHASE:-unknown}|${message}" >> "${CHECKPOINT_FILE}"
    echo "{\"timestamp\":\"${ts}\",\"level\":\"${level}\",\"phase\":\"${CURRENT_PHASE:-unknown}\",\"message\":\"${message}\"}" > "${DEPLOY_STATUS_FILE}"
}

set_current_phase() {
    CURRENT_PHASE="$1"
    record_checkpoint "PHASE_START" "Starting $1"
}

check_phase_done() {
    grep -q "DONE:$1" "${CHECKPOINT_FILE}" 2>/dev/null
}

mark_phase_done() {
    echo "DONE:$1" >> "${CHECKPOINT_FILE}"
}

pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
sock_exists() { [ -S "$1" ]; }

# ===========================================================================
# Phase 1: System Preparation
# ===========================================================================
set_current_phase "system-preparation"
log_info "Phase 1: System preparation"

if ! check_phase_done "system-preparation"; then
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq curl git unzip ca-certificates gnupg lsb-release software-properties-common ufw fail2ban logrotate cron rsyslog
    mark_phase_done "system-preparation"
else
    log_info "Phase 1 already complete — skipping"
fi

# ===========================================================================
# Phase 2: Swap Space
# ===========================================================================
set_current_phase "swap-configuration"
log_info "Phase 2: Swap space"

if ! check_phase_done "swap-configuration"; then
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl vm.swappiness=10
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    mark_phase_done "swap-configuration"
else
    log_info "Phase 2 already complete — skipping"
fi

# ===========================================================================
# Phase 3: PHP
# ===========================================================================
set_current_phase "php-install"
log_info "Phase 3: PHP ${PHP_VERSION}"

if ! check_phase_done "php-install"; then
    if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        add-apt-repository ppa:ondrej/php -y
        apt-get update -qq
    fi
    apt-get install -y -qq php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql php${PHP_VERSION}-sqlite3 php${PHP_VERSION}-pdo php${PHP_VERSION}-pdo-sqlite php${PHP_VERSION}-xml php${PHP_VERSION}-mbstring php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-gd php${PHP_VERSION}-redis php${PHP_VERSION}-tokenizer php${PHP_VERSION}-fileinfo

    PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"
    if ! sock_exists "${PHP_FPM_SOCK}"; then
        for sock in "/run/php/php${PHP_VERSION}-fpm.sock" "/var/run/php/php${PHP_VERSION}-fpm.sock"; do
            if sock_exists "${sock}"; then PHP_FPM_SOCK="${sock}"; break; fi
        done
    fi
    mark_phase_done "php-install"
else
    log_info "Phase 3 already complete — skipping"
fi

# ===========================================================================
# Phase 4: Docker
# ===========================================================================
set_current_phase "docker-install"
log_info "Phase 4: Docker"

if ! check_phase_done "docker-install"; then
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
    if ! docker compose version &>/dev/null; then
        apt-get install -y -qq docker-compose-plugin
    fi
    if ! getent group docker | grep -qw www-data; then
        usermod -aG docker www-data
    fi
    mark_phase_done "docker-install"
else
    log_info "Phase 4 already complete — skipping"
fi

# ===========================================================================
# Phase 5: Composer
# ===========================================================================
set_current_phase "composer-install"
log_info "Phase 5: Composer"

if ! check_phase_done "composer-install"; then
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
    fi
    mark_phase_done "composer-install"
else
    log_info "Phase 5 already complete — skipping"
fi

# ===========================================================================
# Phase 6: Deploy Application Code
# ===========================================================================
set_current_phase "app-deploy"
log_info "Phase 6: Deploying application"

if ! check_phase_done "app-deploy"; then
    mkdir -p "${ROOT}"
    chown -R ubuntu:www-data "${ROOT}"
    chmod -R 775 "${ROOT}"
    if [ ! -d "${ROOT}/.git" ]; then
        git clone "${REPO_URL}" "${ROOT}"
    else
        cd "${ROOT}"
        git fetch origin --tags --quiet
        git pull origin main --quiet || git pull origin master --quiet || true
    fi
    cd "${ROOT}"
    chown -R www-data:www-data "${ROOT}"
    mark_phase_done "app-deploy"
else
    log_info "Phase 6 already complete — pulling latest"
    cd "${ROOT}"
    git fetch origin --tags --quiet
    git pull origin main --quiet || git pull origin master --quiet || true
    chown -R www-data:www-data "${ROOT}"
fi

# ===========================================================================
# Phase 7: PHP Dependencies
# ===========================================================================
set_current_phase "dependencies-install"
log_info "Phase 7: Dependencies"

if ! check_phase_done "dependencies-install"; then
    composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${ROOT}" 2>&1 | tail -5
    mark_phase_done "dependencies-install"
else
    log_info "Phase 7 already complete — skipping"
fi

# ===========================================================================
# Phase 8: Configure .env
# ===========================================================================
set_current_phase "env-config"
log_info "Phase 8: Environment configuration"

if ! check_phase_done "env-config"; then
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
    mark_phase_done "env-config"
else
    log_info "Phase 8 already complete — skipping"
fi

# ===========================================================================
# Phase 9: App Key + Optimization
# ===========================================================================
set_current_phase "app-optimize"
log_info "Phase 9: App key and optimization"

if ! check_phase_done "app-optimize"; then
    grep -q '^APP_KEY=base64:' "${ROOT}/.env" 2>/dev/null || php "${ROOT}/artisan" key:generate --force
    php "${ROOT}/artisan" config:cache --force
    php "${ROOT}/artisan" route:cache --force
    php "${ROOT}/artisan" view:cache --force
    php "${ROOT}/artisan" event:cache --force
    mark_phase_done "app-optimize"
else
    log_info "Phase 9 already complete — skipping"
fi

# ===========================================================================
# Phase 10: Database Migrations
# ===========================================================================
set_current_phase "database-migrate"
log_info "Phase 10: Migrations"

if ! check_phase_done "database-migrate"; then
    if [ "${DB_CONNECTION}" = "sqlite" ] && [ -f "${DB_PATH}" ]; then
        php "${ROOT}/artisan" migrate --force 2>&1 | tail -3 || log_warn "Migration may have failed"
    fi
    mark_phase_done "database-migrate"
else
    log_info "Phase 10 already complete — skipping"
fi

# ===========================================================================
# Phase 11: SSL Setup
# ===========================================================================
set_current_phase "ssl-setup"
log_info "Phase 11: SSL setup"

if ! check_phase_done "ssl-setup"; then
    apt-get install -y -qq certbot python3-certbot-nginx
    mkdir -p "${SSL_DIR}"
    chown -R www-data:www-data "${SSL_DIR}"
    systemctl enable --now nginx || true
    mark_phase_done "ssl-setup"
else
    log_info "Phase 11 already complete — skipping"
fi

# ===========================================================================
# Phase 12: PHP-FPM Tuning
# ===========================================================================
set_current_phase "php-fpm-tune"
log_info "Phase 12: PHP-FPM tuning"

if ! check_phase_done "php-fpm-tune"; then
    FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    if [ -f "${FPM_CONF}" ]; then
        sed -i 's/^pm = .*/pm = dynamic/' "${FPM_CONF}"
        sed -i 's/^pm.max_children = .*/pm.max_children = 6/' "${FPM_CONF}"
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 3/' "${FPM_CONF}"
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "${FPM_CONF}"
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 4/' "${FPM_CONF}"
        sed -i 's/^pm.max_requests = .*/pm.max_requests = 1000/' "${FPM_CONF}"
        systemctl restart "php${PHP_VERSION}-fpm"
    fi
    mark_phase_done "php-fpm-tune"
else
    log_info "Phase 12 already complete — skipping"
fi

# ===========================================================================
# Phase 13: Nginx Configuration
# ===========================================================================
set_current_phase "nginx-config"
log_info "Phase 13: Nginx configuration"

if ! check_phase_done "nginx-config"; then
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
    nginx -t 2>/dev/null && (systemctl enable --now nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true)
    mark_phase_done "nginx-config"
else
    log_info "Phase 13 already complete — skipping"
fi

# ===========================================================================
# Phase 14: Let's Encrypt SSL
# ===========================================================================
set_current_phase "ssl-letsencrypt"
log_info "Phase 14: Let's Encrypt"

if ! check_phase_done "ssl-letsencrypt"; then
    SSL_CERT_READY=false
    if certbot certonly --nginx --non-interactive --agree-tos --email "admin@${PANEL_SUBDOMAIN}" -d "${PANEL_SUBDOMAIN}" --rsa-key-size 4096 --force-renewal 2>/dev/null; then
        SSL_CERT_READY=true
        systemctl reload nginx 2>/dev/null || true
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    else
        log_warn "SSL certificate could not be obtained — ensure DNS ${PANEL_SUBDOMAIN} points to this instance"
    fi
    mark_phase_done "ssl-letsencrypt"
else
    log_info "Phase 14 already complete — skipping"
fi

# ===========================================================================
# Phase 15: Firewall + Fail2ban
# ===========================================================================
set_current_phase "firewall-config"
log_info "Phase 15: Firewall and Fail2ban"

if ! check_phase_done "firewall-config"; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    echo "y" | ufw enable
    ufw limit 22/tcp 2>/dev/null || true
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
    mark_phase_done "firewall-config"
else
    log_info "Phase 15 already complete — skipping"
fi

# ===========================================================================
# Phase 16: Log Rotation + Cron
# ===========================================================================
set_current_phase "log-cron-config"
log_info "Phase 16: Log rotation and cron"

if ! check_phase_done "log-cron-config"; then
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
    (crontab -u www-data -l 2>/dev/null | grep -v 'artisan schedule'; echo "* * * * * cd /opt/dstack-panel && php artisan schedule:run >> /opt/dstack-panel/storage/logs/scheduler.log 2>&1") | crontab -u www-data -
    mark_phase_done "log-cron-config"
else
    log_info "Phase 16 already complete — skipping"
fi

# ===========================================================================
# Phase 17: Start Services
# ===========================================================================
set_current_phase "services-start"
log_info "Phase 17: Starting services"

if ! check_phase_done "services-start"; then
    if [ -f "${COMPOSE_FILE}" ]; then
        cd "${ROOT}"
        sudo -u www-data docker compose up -d --remove-orphans 2>/dev/null || log_warn "Docker Compose stack start failed"
    fi
    mark_phase_done "services-start"
else
    log_info "Phase 17 already complete — skipping"
fi

# ===========================================================================
# Phase 18: Health Check
# ===========================================================================
set_current_phase "health-check"
log_info "Phase 18: Health verification"

sleep 3
pgrep -x "php-fpm${PHP_VERSION}" > /dev/null || systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
systemctl is-active --quiet nginx || systemctl restart nginx 2>/dev/null || true
docker info > /dev/null 2>&1 || systemctl restart docker 2>/dev/null || true
if [ "${DB_CONNECTION}" = "sqlite" ] && [ -f "${DB_PATH}" ]; then
    log_info "SQLite database: ready"
fi

# ===========================================================================
# Phase 19: Chada.digital App Deployment
# ===========================================================================
if [ "${CHADA_DIGITAL_ENABLED}" = "true" ]; then
    set_current_phase "chada-digital-deploy"
    log_info "Phase 19: Deploying chada.digital"

    if ! check_phase_done "chada-digital-deploy"; then
        mkdir -p "${CHADA_DIGITAL_ROOT}"
        chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}"
        if [ ! -d "${CHADA_DIGITAL_ROOT}/.git" ]; then
            git clone "${CHADA_DIGITAL_REPO}" "${CHADA_DIGITAL_ROOT}" 2>/dev/null || log_warn "Git clone failed for chada.digital"
        else
            cd "${CHADA_DIGITAL_ROOT}"
            git fetch origin --tags --quiet
            git pull origin "${CHADA_DIGITAL_BRANCH}" --quiet || true
        fi
        if [ -d "${CHADA_DIGITAL_ROOT}" ]; then
            cd "${CHADA_DIGITAL_ROOT}"
            chown -R www-data:www-data "${CHADA_DIGITAL_ROOT}"
            if [ -f "${CHADA_DIGITAL_ROOT}/composer.json" ]; then
                composer install --no-dev --optimize-autoloader --no-interaction --working-dir="${CHADA_DIGITAL_ROOT}" 2>&1 | tail -5 || log_warn "Composer install failed for chada.digital"
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
                php "${CHADA_DIGITAL_ROOT}/artisan" migrate --force 2>/dev/null || log_warn "Chada.digital migrations may have failed"
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
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
            if certbot certonly --nginx --non-interactive --agree-tos --email "admin@${CHADA_DIGITAL_SUBDOMAIN}" -d "${CHADA_DIGITAL_SUBDOMAIN}" --rsa-key-size 4096 --force-renewal 2>/dev/null; then
                log_info "SSL certificate obtained for ${CHADA_DIGITAL_SUBDOMAIN}"
                systemctl reload nginx 2>/dev/null || true
            else
                log_warn "SSL certificate could not be obtained for ${CHADA_DIGITAL_SUBDOMAIN}"
            fi
            log_info "Chada.digital app deployment complete"
        else
            log_warn "Chada.digital repo not available — skipping"
        fi
        mark_phase_done "chada-digital-deploy"
    else
        log_info "Phase 19 already complete — skipping"
    fi
fi

# ===========================================================================
# Final Output
# ===========================================================================
set_current_phase "complete"
log_info "========================================="
log_info " DStack Panel bootstrap complete"
log_info "========================================="
log_info "  Application root: ${ROOT}"
log_info "  Panel URL: https://${PANEL_SUBDOMAIN}"
log_info "  PHP version: ${PHP_VERSION}"
log_info "  Database: ${DB_CONNECTION}"
log_info "  SSL ready: ${SSL_CERT_READY:-false}"
log_info "========================================="
log_info " Next steps:"
log_info "  1. Update DNS ${PANEL_SUBDOMAIN} → this instance's public IP"
if [ "${CHADA_DIGITAL_ENABLED}" = "true" ]; then
    log_info "  2. Update DNS ${CHADA_DIGITAL_SUBDOMAIN} → this instance's public IP"
fi
log_info "  3. If SSL failed, run: certbot certonly --nginx -d ${PANEL_SUBDOMAIN}"
log_info "  4. Check logs: tail -f ${ROOT}/storage/logs/laravel.log"
log_info "========================================="

echo "{\"phase\":\"complete\",\"status\":\"done\",\"finished_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" > "${DEPLOY_STATUS_FILE}"
