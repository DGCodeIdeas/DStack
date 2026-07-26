#!/usr/bin/env bash
# =============================================================================
# DStack Existing EC2 Setup Handler
# =============================================================================
# Use this script when you already have an EC2 and RDS instance running.
# It generates a bootstrap script that you can run directly on the existing instance.
# =============================================================================
# Usage: bash cloud/setup-existing-ec2.sh
# Prerequisites: AWS CLI installed and configured, cloud/config.env populated
# =============================================================================

set -euo pipefail

# Verbosity toggle -- see cloud/lib/debug.sh for usage.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/debug.sh"

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
log "Starting DStack existing EC2 setup handler..."

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    error "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
fi

log "AWS CLI found: $(aws --version)"

# Check AWS credentials
log "Verifying AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    error "AWS credentials not configured. Run 'aws configure' or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY"
fi

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
    "AWS_REGION"
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
# Find existing EC2 instance
# -----------------------------------------------------------------------------
log "Looking for existing EC2 instance with tag: ${INSTANCE_NAME_TAG:-dstack-prod}..."

INSTANCE_ID=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME_TAG:-dstack-prod}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [[ "${INSTANCE_ID}" == "None" || -z "${INSTANCE_ID}" ]]; then
    error "No running EC2 instance found with tag Name=${INSTANCE_NAME_TAG:-dstack-prod}. Please verify the instance exists and is running."
fi

log "Found instance: ${INSTANCE_ID}"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "None" ]]; then
    error "Could not retrieve public IP for instance ${INSTANCE_ID}"
fi

log "Public IP: ${PUBLIC_IP}"

# -----------------------------------------------------------------------------
# Generate bootstrap script for manual execution
# -----------------------------------------------------------------------------
log "Generating bootstrap script for existing instance..."

USER_DATA_SCRIPT="cloud/ec2-setup.sh"

if [[ ! -f "${USER_DATA_SCRIPT}" ]]; then
    error "Bootstrap script not found: ${USER_DATA_SCRIPT}"
fi

# Create output directory
OUTPUT_DIR="cloud/output"
mkdir -p "${OUTPUT_DIR}"

# Generate the combined script with injected variables
OUTPUT_SCRIPT="${OUTPUT_DIR}/bootstrap-existing.sh"

log "Injecting config variables into bootstrap script..."
{
    echo "#!/usr/bin/env bash"
    echo "# DStack Bootstrap Script for Existing EC2"
    echo "# Generated on $(date)"
    echo "# Run this script directly on your EC2 instance as root"
    echo ""
    echo "# Variables injected from cloud/config.env"
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
    echo "# Now run the actual bootstrap"
    tail -n +2 "${USER_DATA_SCRIPT}"
} > "${OUTPUT_SCRIPT}"

chmod +x "${OUTPUT_SCRIPT}"

# Also create a one-line SSH command for convenience
SSH_CMD_FILE="${OUTPUT_DIR}/ssh-bootstrap-command.txt"
{
    echo "# Run this command to bootstrap your existing EC2 instance:"
    echo "ssh -i ~/.ssh/${AWS_KEY_NAME}.pem ${SSH_USER}@${PUBLIC_IP} 'sudo bash -s' < ${OUTPUT_SCRIPT}"
    echo ""
    echo "# Or upload and run manually:"
    echo "scp -i ~/.ssh/${AWS_KEY_NAME}.pem ${OUTPUT_SCRIPT} ${SSH_USER}@${PUBLIC_IP}:/tmp/"
    echo "ssh -i ~/.ssh/${AWS_KEY_NAME}.pem ${SSH_USER}@${PUBLIC_IP} 'sudo bash /tmp/bootstrap-existing.sh'"
} > "${SSH_CMD_FILE}"

# -----------------------------------------------------------------------------
# Output results
# -----------------------------------------------------------------------------
echo ""
echo "==============================================================================="
echo "  DStack Existing EC2 Setup Handler Complete!"
echo "==============================================================================="
echo ""
echo "Instance Details:"
echo "  Instance ID:     ${INSTANCE_ID}"
echo "  Public IP:       ${PUBLIC_IP}"
echo ""
echo "Generated Files:"
echo "  Bootstrap script: ${OUTPUT_SCRIPT}"
echo "  SSH command:      ${SSH_CMD_FILE}"
echo ""
echo "Next Steps:"
echo "==============================================================================="
echo ""
echo "Option 1 - One-line SSH execution:"
echo "  ssh -i ~/.ssh/${AWS_KEY_NAME}.pem ${SSH_USER}@${PUBLIC_IP} 'sudo bash -s' < ${OUTPUT_SCRIPT}"
echo ""
echo "Option 2 - Manual upload and run:"
cat "${SSH_CMD_FILE}" | tail -n +2
echo ""
echo "3. Monitor bootstrap progress on the instance:"
echo "   ssh -i ~/.ssh/${AWS_KEY_NAME}.pem ${SSH_USER}@${PUBLIC_IP} 'tail -f /var/log/dstack-bootstrap.log'"
echo ""
echo "4. Wait for bootstrap to complete (see expected milestones in guide)"
echo ""
echo "5. Verify containers:"
echo "   ssh -i ~/.ssh/${AWS_KEY_NAME}.pem ${SSH_USER}@${PUBLIC_IP} 'cd /opt/dstack/docker && sudo docker compose ps'"
echo ""
echo "6. Create the database on RDS (if not exists):"
echo "   mysql -h ${RDS_ENDPOINT} -u ${RDS_DB_USER} -p -e 'CREATE DATABASE IF NOT EXISTS ${RDS_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'"
echo ""
echo "==============================================================================="

log "Bootstrap script generated. Run it on your existing instance to complete setup."