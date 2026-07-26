#!/usr/bin/env bash
# =============================================================================
# DStack EC2 Bootstrap Script (runs as user-data on EC2 first boot)
# =============================================================================
# This script runs as root via cloud-init on first boot of the EC2 instance.
# It installs Docker, clones the repo, configures environment, starts services,
# and optionally configures Let's Encrypt SSL.
# =============================================================================

set -euo pipefail

# Verbosity toggle -- see cloud/lib/debug.sh for usage.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/debug.sh"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
exec > >(tee -a /var/log/dstack-bootstrap.log) 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

# -----------------------------------------------------------------------------
# Configuration (passed via user-data or environment)
# These should be injected via the provision-ec2.sh user-data encoding
# -----------------------------------------------------------------------------
# Required (injected by provision-ec2.sh via config.env)
GITHUB_REPO_URL="${GITHUB_REPO_URL:-}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_DB_NAME="${RDS_DB_NAME:-dstack}"
RDS_DB_USER="${RDS_DB_USER:-admin}"
RDS_DB_PASSWORD="${RDS_DB_PASSWORD:-}"
DOMAIN="${DOMAIN:-}"
EMAIL_FOR_LETSENCRYPT="${EMAIL_FOR_LETSENCRYPT:-}"
SSH_USER="${SSH_USER:-ubuntu}"

# Optional
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
COMPOSE_EXTRA_ENV="${COMPOSE_EXTRA_ENV:-}"

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
log "Starting DStack bootstrap..."

required_vars=("GITHUB_REPO_URL" "RDS_ENDPOINT" "RDS_DB_NAME" "RDS_DB_USER" "RDS_DB_PASSWORD")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable $var is not set"
        exit 1
    fi
done

log "Configuration validated"

# -----------------------------------------------------------------------------
# System update and package installation
# -----------------------------------------------------------------------------
log "Updating package index..."
apt-get update -y

log "Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    software-properties-common \
    jq \
    unzip

# -----------------------------------------------------------------------------
# Install Docker (idempotent)
# -----------------------------------------------------------------------------
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor > /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

log "Docker version: $(docker --version)"
log "Docker Compose version: $(docker compose version)"

# Add ubuntu user to docker group
usermod -aG docker "${SSH_USER}"

# Enable and start Docker
systemctl enable docker
systemctl start docker

# -----------------------------------------------------------------------------
# Configure Docker daemon (DNS + log rotation) BEFORE any docker build/pull.
# Ubuntu's systemd-resolved stub (127.0.0.53) is unreachable inside containers,
# so builds that need DNS (composer, pecl) fail without this.
# -----------------------------------------------------------------------------
log "Configuring Docker daemon (DNS + log rotation)..."
cat > /etc/docker/daemon.json <<'EOF'
{
  "dns": ["8.8.8.8", "8.8.4.4"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker
log "Docker daemon reconfigured."

log "Fixing /etc/resolv.conf for Docker build DNS..."
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# -----------------------------------------------------------------------------
# Add 2 GB swap. t3.small has 2 GB RAM; imagick's PECL build compiles from
# source and the OOM killer kills the build without swap headroom.
# -----------------------------------------------------------------------------
if [[ ! -f /swapfile ]]; then
    log "Creating 2 GB swapfile..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap enabled: $(free -h | grep Swap)"
fi

# -----------------------------------------------------------------------------
# Release port 80 in case a bare-metal web server is present on the AMI.
# -----------------------------------------------------------------------------
log "Ensuring port 80 is free..."
systemctl stop apache2 2>/dev/null && systemctl disable apache2 2>/dev/null || true
systemctl stop nginx   2>/dev/null && systemctl disable nginx   2>/dev/null || true
log "Port 80 cleared."

# -----------------------------------------------------------------------------
# Install Certbot (for Let's Encrypt)
# -----------------------------------------------------------------------------
log "Installing Certbot..."
DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx

# -----------------------------------------------------------------------------
# Clone DStack repository
# -----------------------------------------------------------------------------
log "Cloning DStack repository..."
REPO_DIR="/opt/dstack"

if [[ -d "${REPO_DIR}" ]]; then
    log "Repository already exists, pulling latest..."
    cd "${REPO_DIR}"
    git fetch origin
    git reset --hard "origin/${GITHUB_BRANCH}"
else
    if [[ -n "${GITHUB_TOKEN}" ]]; then
        # Use token for private repos
        REPO_URL_WITH_TOKEN="https://${GITHUB_TOKEN}@${GITHUB_REPO_URL#https://}"
        git clone -b "${GITHUB_BRANCH}" "${REPO_URL_WITH_TOKEN}" "${REPO_DIR}"
    else
        git clone -b "${GITHUB_BRANCH}" "${GITHUB_REPO_URL}" "${REPO_DIR}"
    fi
fi

cd "${REPO_DIR}"
log "Repository cloned to ${REPO_DIR}"

# -----------------------------------------------------------------------------
# Create .env file for docker-compose
# -----------------------------------------------------------------------------
log "Creating .env file for docker-compose..."

cat > "${REPO_DIR}/.env" <<EOF
# DStack Docker Compose Environment
# Generated by ec2-setup.sh on $(date)

# =============================================================================
# Database (RDS)
# =============================================================================
DB_HOST=${RDS_ENDPOINT}
DB_PORT=${RDS_PORT}
DB_NAME=${RDS_DB_NAME}
DB_USER=${RDS_DB_USER}
DB_PASSWORD=${RDS_DB_PASSWORD}

# =============================================================================
# Application
# =============================================================================
APP_ENV=production
APP_DEBUG=false
APP_URL=http://localhost:5000

# =============================================================================
# Domain & SSL (for nginx/Let's Encrypt)
# =============================================================================
DOMAIN=${DOMAIN}
EMAIL_FOR_LETSENCRYPT=${EMAIL_FOR_LETSENCRYPT}

# =============================================================================
# PHP / Nginx
# =============================================================================
PHP_MEMORY_LIMIT=256M
PHP_MAX_EXECUTION_TIME=300
PHP_UPLOAD_MAX_FILESIZE=100M
PHP_POST_MAX_SIZE=100M

# =============================================================================
# Docker Compose
# =============================================================================
COMPOSE_PROJECT_NAME=dstack

# =============================================================================
# Extra environment variables (from config)
# =============================================================================
${COMPOSE_EXTRA_ENV}
EOF

log ".env file created at ${REPO_DIR}/.env"

# Compose resolves .env relative to its own directory (docker/), not repo root.
cp "${REPO_DIR}/.env" "${REPO_DIR}/docker/.env"
log ".env synced to ${REPO_DIR}/docker/.env"

# -----------------------------------------------------------------------------
# Create docker-compose.override.yml for RDS
# -----------------------------------------------------------------------------
log "Creating docker-compose.override.yml for RDS..."
cat > "${REPO_DIR}/docker/docker-compose.override.yml" <<EOF
# Auto-generated by ec2-setup.sh
# Disables local MySQL (using RDS), points phpMyAdmin at RDS.

services:
  mysql:
    profiles:
      - disabled

  phpmyadmin:
    depends_on: {}
    environment:
      PMA_HOST: ${RDS_ENDPOINT}
      PMA_PORT: ${RDS_PORT}
      MYSQL_ROOT_PASSWORD: ${RDS_DB_PASSWORD}
EOF

if [[ -n "${DOMAIN}" && -n "${EMAIL_FOR_LETSENCRYPT}" ]]; then
    cat >> "${REPO_DIR}/docker/docker-compose.override.yml" <<'EOF'

  nginx:
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./ssl:/etc/nginx/ssl:ro
EOF
fi

log "docker-compose.override.yml created"

# -----------------------------------------------------------------------------
# Create SSL directory and placeholder (certbot will populate)
# -----------------------------------------------------------------------------
mkdir -p "${REPO_DIR}/docker/ssl"

# -----------------------------------------------------------------------------
# Start Docker Compose services
# -----------------------------------------------------------------------------
log "Starting Docker Compose services..."
cd "${REPO_DIR}/docker"
docker compose up -d --build

# Wait for services to be healthy
log "Waiting for services to start..."
sleep 10

# Check service status
docker compose ps

# -----------------------------------------------------------------------------
# Configure Let's Encrypt SSL (if domain configured)
# -----------------------------------------------------------------------------
if [[ -n "${DOMAIN}" && -n "${EMAIL_FOR_LETSENCRYPT}" ]]; then
    log "Configuring Let's Encrypt SSL for ${DOMAIN}..."

    # Wait a bit more for nginx to be ready
    sleep 5

    # Stop nginx temporarily for standalone certbot
    docker compose stop nginx

    # Obtain certificate using standalone mode (port 80 must be free)
    certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "${EMAIL_FOR_LETSENCRYPT}" \
        -d "${DOMAIN}" \
        --preferred-challenges http

    # Copy certificates to docker ssl directory
    cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${REPO_DIR}/docker/ssl/fullchain.pem"
    cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${REPO_DIR}/docker/ssl/privkey.pem"

    # Set up auto-renewal cron job
    cat > /etc/cron.d/certbot-renew <<EOF
# Certbot auto-renewal for DStack
0 3 * * * root certbot renew --quiet --deploy-hook "cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${REPO_DIR}/docker/ssl/fullchain.pem && cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${REPO_DIR}/docker/ssl/privkey.pem && cd ${REPO_DIR}/docker && docker compose restart nginx"
EOF

    # Restart nginx with SSL
    docker compose start nginx

    log "Let's Encrypt SSL configured for ${DOMAIN}"
    log "Certificates will auto-renew via cron (daily at 3 AM)"
else
    warn "DOMAIN or EMAIL_FOR_LETSENCRYPT not set - skipping Let's Encrypt setup"
    warn "To enable HTTPS later, set DOMAIN and EMAIL_FOR_LETSENCRYPT in config.env and re-run bootstrap"
fi

# -----------------------------------------------------------------------------
# Final status and URLs
# -----------------------------------------------------------------------------
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname 2>/dev/null || echo "unknown")

echo ""
echo "==============================================================================="
echo "  DStack Bootstrap Complete!"
echo "==============================================================================="
echo ""
echo "Services started:"
docker compose ps
echo ""
echo "Access URLs:"
echo "  Dashboard (HTTP):  http://${PUBLIC_IP}:5000"
if [[ -n "${DOMAIN}" && -n "${EMAIL_FOR_LETSENCRYPT}" ]]; then
    echo "  Dashboard (HTTPS): https://${DOMAIN}"
fi
echo "  phpMyAdmin:        http://${PUBLIC_IP}:8080"
echo ""
echo "RDS Connection (from this instance):"
echo "  Host: ${RDS_ENDPOINT}"
echo "  Port: ${RDS_PORT}"
echo "  Database: ${RDS_DB_NAME}"
echo "  User: ${RDS_DB_USER}"
echo ""
echo "SSH Tunnel for local RDS access (run from YOUR machine):"
echo "  ssh -i ~/.ssh/your-key.pem -L 3306:${RDS_ENDPOINT}:3306 ${SSH_USER}@${PUBLIC_IP}"
echo ""
echo "Logs:"
echo "  Bootstrap log:     /var/log/dstack-bootstrap.log"
echo "  Docker logs:       cd ${REPO_DIR}/docker && docker compose logs -f"
echo "  Cloud-init log:    /var/log/cloud-init-output.log"
echo ""
echo "==============================================================================="
echo "  Next Steps:"
echo "==============================================================================="
echo "1. Visit the dashboard URL above to complete setup"
echo "2. Configure your DNS to point ${DOMAIN:-your-domain} to ${PUBLIC_IP}"
echo "3. Set up SSH tunnel for local database access if needed"
echo "4. Monitor logs: docker compose logs -f"
echo "==============================================================================="

log "Bootstrap completed successfully!"