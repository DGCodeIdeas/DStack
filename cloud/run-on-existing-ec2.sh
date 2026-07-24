#!/usr/bin/env bash
# =============================================================================
# DStack Run on Existing EC2
# =============================================================================
# Use this script when you already have an EC2 and RDS instance running.
# It runs the bootstrap script directly on the specified instance via SSH.
# =============================================================================
# Usage: bash cloud/run-on-existing-ec2.sh <PUBLIC_IP>
# Example: bash cloud/run-on-existing-ec2.sh 123.45.67.89
# Prerequisites: AWS CLI installed and configured, cloud/config.env populated
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Check for IP argument
# -----------------------------------------------------------------------------
if [[ -z "${1:-}" ]]; then
    error "Usage: $0 <PUBLIC_IP>"
    error "Example: $0 123.45.67.89"
    exit 1
fi

PUBLIC_IP="$1"
log "Target EC2 instance: ${PUBLIC_IP}"

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
if ! command -v aws &> /dev/null; then
    error "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
fi

log "AWS CLI found: $(aws --version)"

# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------
CONFIG_FILE="cloud/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    error "Config file not found: ${CONFIG_FILE}. Copy cloud/config.env.example to cloud/config.env and fill in your values."
fi

log "Loading configuration from ${CONFIG_FILE}..."
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Validate required variables
required_vars=(
    "RDS_ENDPOINT"
    "RDS_PORT"
    "RDS_DB_NAME"
    "RDS_DB_USER"
    "RDS_DB_PASSWORD"
    "GITHUB_REPO_URL"
    "SSH_USER"
    "AWS_KEY_NAME"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable ${var} is not set in ${CONFIG_FILE}"
    fi
done

log "Configuration validated."

# -----------------------------------------------------------------------------
# Check SSH key
# -----------------------------------------------------------------------------
SSH_KEY_PATH="${HOME}/.ssh/${AWS_KEY_NAME}.pem"
if [[ ! -f "${SSH_KEY:-}" && ! -f "${SSH_KEY_PATH}" ]]; then
    error "SSH key not found at ${SSH_KEY_PATH}"
fi

# Use SSH_KEY env var if set, otherwise use default path
SSH_KEY="${SSH_KEY:-${SSH_KEY_PATH}}"

# -----------------------------------------------------------------------------
# Generate and run bootstrap script
# -----------------------------------------------------------------------------
log "Generating bootstrap script..."

# Create a temporary file for the combined script
TEMP_SCRIPT=$(mktemp)

# Generate the script with injected variables
{
    echo "#!/usr/bin/env bash"
    echo "# DStack Bootstrap Script for Existing EC2"
    echo "# Generated on $(date)"
    echo ""
    echo "export GITHUB_REPO_URL=\"${GITHUB_REPO_URL}\""
    echo "export GITHUB_BRANCH=\"${GITHUB_BRANCH:-main}\""
    echo "export GITHUB_TOKEN=\"${GITHUB_TOKEN:-}\""
    echo "export RDS_ENDPOINT=\"${RDS_ENDPOINT}\""
    echo "export RDS_PORT=\"${RDS_PORT:-3306}\""
    echo "export RDS_DB_NAME=\"${RDS_DB_NAME}\""
    echo "export RDS_DB_USER=\"${RDS_DB_USER}\""
    echo "export RDS_DB_PASSWORD=\"${RDS_DB_PASSWORD}\""
    echo "export DOMAIN=\"${DOMAIN:-}\""
    echo "export EMAIL_FOR_LETSENCRYPT=\"${EMAIL_FOR_LETSENCRYPT:-}\""
    echo "export SSH_USER=\"${SSH_USER:-ubuntu}\""
    echo "export COMPOSE_EXTRA_ENV=\"${COMPOSE_EXTRA_ENV:-}\""
    echo ""
    # Source the bootstrap script
    echo "source /dev/stdin << 'BOOTSTRAP_EOF'"
    cat "cloud/bootstrap-existing.sh"
    echo "BOOTSTRAP_EOF"
} > "${TEMP_SCRIPT}"

log "Running bootstrap on ${PUBLIC_IP}..."
log "This will take ~15-20 minutes (imagick PECL compile, etc.)"
echo ""

# Run via SSH
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${PUBLIC_IP}" 'sudo bash -s' < "${TEMP_SCRIPT}"

rm -f "${TEMP_SCRIPT}"

log "Bootstrap completed on ${PUBLIC_IP}"