#!/usr/bin/env bash
# =============================================================================
# DStack EC2 Provisioning Script
# Run this on your LOCAL machine to provision an EC2 instance for DStack
# =============================================================================
# Usage: bash cloud/provision-ec2.sh
# Prerequisites: AWS CLI installed and configured, cloud/config.env populated
# =============================================================================

set -euo pipefail

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
log "Starting DStack EC2 provisioning..."

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

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Authenticated as account: ${ACCOUNT_ID}"

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
    "AWS_INSTANCE_TYPE"
    "AWS_KEY_NAME"
    "RDS_ENDPOINT"
    "RDS_PORT"
    "RDS_DB_NAME"
    "RDS_DB_USER"
    "RDS_DB_PASSWORD"
    "GITHUB_REPO_URL"
    "SSH_USER"
    "SECURITY_GROUP_NAME"
    "INSTANCE_NAME_TAG"
    "AMI_ID"
    "ROOT_VOLUME_SIZE"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required variable ${var} is not set in ${CONFIG_FILE}"
    fi
done

log "Configuration validated."

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------
log "Checking/creating security group: ${SECURITY_GROUP_NAME}"

# Get VPC ID (default VPC)
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Vpcs[0].VpcId' \
    --output text)

if [[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]]; then
    error "No default VPC found in region ${AWS_REGION}. Specify a VPC or create a default VPC."
fi

log "Using VPC: ${VPC_ID}"

# Check if security group exists
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --region "${AWS_REGION}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
    log "Creating security group: ${SECURITY_GROUP_NAME}"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SECURITY_GROUP_NAME}" \
        --description "${SECURITY_GROUP_DESC:-DStack security group - SSH, HTTP, HTTPS, MySQL}" \
        --vpc-id "${VPC_ID}" \
        --region "${AWS_REGION}" \
        --query 'GroupId' \
        --output text)

    # Add tags
    aws ec2 create-tags \
        --resources "${SG_ID}" \
        --tags "Key=Name,Value=${SECURITY_GROUP_NAME}" "Key=Project,Value=DStack" \
        --region "${AWS_REGION}"

    # Add ingress rules
    log "Adding ingress rules to security group..."

    # SSH (22) - from anywhere (restrict in production!)
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" > /dev/null

    # HTTP (80)
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" > /dev/null

    # HTTPS (443)
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" > /dev/null

    # MySQL (3306) - from the security group itself (self-referencing for RDS tunnel)
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 3306 \
        --source-group "${SG_ID}" \
        --region "${AWS_REGION}" > /dev/null

    log "Security group created: ${SG_ID}"
else
    log "Security group already exists: ${SG_ID}"
fi

# -----------------------------------------------------------------------------
# Prepare user-data script (ec2-setup.sh)
# -----------------------------------------------------------------------------
log "Preparing user-data script..."

USER_DATA_SCRIPT="cloud/ec2-setup.sh"

if [[ ! -f "${USER_DATA_SCRIPT}" ]]; then
    error "User-data script not found: ${USER_DATA_SCRIPT}"
fi

# ec2-setup.sh reads its config from environment variables (${VAR:-}). Those
# variables exist in THIS shell (sourced from config.env above) but user-data
# runs in a fresh shell on the instance, so they must be written into the
# script itself before encoding it.
log "Injecting config variables into user-data script..."
INJECTED_VARS=$(cat <<VAREOF
#!/usr/bin/env bash
# Variables injected by provision-ec2.sh from cloud/config.env
export GITHUB_REPO_URL=$(printf '%q' "${GITHUB_REPO_URL}")
export GITHUB_BRANCH=$(printf '%q' "${GITHUB_BRANCH:-main}")
export GITHUB_TOKEN=$(printf '%q' "${GITHUB_TOKEN:-}")
export RDS_ENDPOINT=$(printf '%q' "${RDS_ENDPOINT}")
export RDS_PORT=$(printf '%q' "${RDS_PORT:-3306}")
export RDS_DB_NAME=$(printf '%q' "${RDS_DB_NAME}")
export RDS_DB_USER=$(printf '%q' "${RDS_DB_USER}")
export RDS_DB_PASSWORD=$(printf '%q' "${RDS_DB_PASSWORD}")
export DOMAIN=$(printf '%q' "${DOMAIN:-}")
export EMAIL_FOR_LETSENCRYPT=$(printf '%q' "${EMAIL_FOR_LETSENCRYPT:-}")
export SSH_USER=$(printf '%q' "${SSH_USER:-ubuntu}")
export COMPOSE_EXTRA_ENV=$(printf '%q' "${COMPOSE_EXTRA_ENV:-}")
VAREOF
)
SETUP_BODY=$(tail -n +2 "${USER_DATA_SCRIPT}")
COMBINED_SCRIPT="${INJECTED_VARS}
${SETUP_BODY}"

# Read the combined script and base64 encode it
USER_DATA=$(printf '%s' "${COMBINED_SCRIPT}" | base64 -w 0)
log "User-data prepared ($(printf '%s' "${COMBINED_SCRIPT}" | wc -l) lines)."

# -----------------------------------------------------------------------------
# Launch EC2 Instance
# -----------------------------------------------------------------------------
log "Launching EC2 instance..."
log "  Region: ${AWS_REGION}"
log "  Instance Type: ${AWS_INSTANCE_TYPE}"
log "  AMI: ${AMI_ID}"
log "  Key: ${AWS_KEY_NAME}"
log "  Security Group: ${SG_ID}"
log "  Name Tag: ${INSTANCE_NAME_TAG}"

# Build tag specifications
TAG_SPECS="ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME_TAG}},{Key=Project,Value=DStack},{Key=Environment,Value=production}]"

# Run instances
RUN_OUTPUT=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${AWS_INSTANCE_TYPE}" \
    --key-name "${AWS_KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --tag-specifications "${TAG_SPECS}" \
    --user-data "${USER_DATA}" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --region "${AWS_REGION}" \
    --output json)

INSTANCE_ID=$(echo "${RUN_OUTPUT}" | jq -r '.Instances[0].InstanceId')

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "null" ]]; then
    error "Failed to launch instance. AWS output: ${RUN_OUTPUT}"
fi

log "Instance launched: ${INSTANCE_ID}"

# -----------------------------------------------------------------------------
# Wait for instance to be running
# -----------------------------------------------------------------------------
log "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"

log "Instance is running. Waiting for status checks..."
aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"

# -----------------------------------------------------------------------------
# Get instance details
# -----------------------------------------------------------------------------
log "Fetching instance details..."

INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0]')

PUBLIC_IP=$(echo "${INSTANCE_INFO}" | jq -r '.PublicIpAddress // "pending"')
PUBLIC_DNS=$(echo "${INSTANCE_INFO}" | jq -r '.PublicDnsName // "pending"')
PRIVATE_IP=$(echo "${INSTANCE_INFO}" | jq -r '.PrivateIpAddress')
AZ=$(echo "${INSTANCE_INFO}" | jq -r '.Placement.AvailabilityZone')

# -----------------------------------------------------------------------------
# Output results
# -----------------------------------------------------------------------------
echo ""
echo "==============================================================================="
echo "  DStack EC2 Instance Provisioned Successfully!"
echo "==============================================================================="
echo ""
echo "Instance Details:"
echo "  Instance ID:     ${INSTANCE_ID}"
echo "  Public IP:       ${PUBLIC_IP}"
echo "  Public DNS:      ${PUBLIC_DNS}"
echo "  Private IP:      ${PRIVATE_IP}"
echo "  Availability Zone: ${AZ}"
echo "  Instance Type:   ${AWS_INSTANCE_TYPE}"
echo "  Security Group:  ${SG_ID}"
echo "  Key Pair:        ${AWS_KEY_NAME}"
echo ""
echo "Next Steps:"
echo "==============================================================================="
echo ""
echo "1. Wait 2-3 minutes for bootstrap to complete (cloud-init runs ec2-setup.sh)"
echo ""
echo "2. Monitor bootstrap progress:"
echo "   ssh -i ~/.ssh/${AWS_KEY_NAME}.pem ${SSH_USER}@${PUBLIC_IP} 'tail -f /var/log/dstack-bootstrap.log'"
echo ""
echo "3. Access the dashboard:"
echo "   HTTP:  http://${PUBLIC_IP}:5000"
if [[ -n "${DOMAIN:-}" && -n "${EMAIL_FOR_LETSENCRYPT:-}" ]]; then
    echo "   HTTPS: https://${DOMAIN} (after DNS points to ${PUBLIC_IP})"
fi
echo "   phpMyAdmin: http://${PUBLIC_IP}:8080"
echo ""
echo "4. SSH tunnel for local RDS access (run from YOUR machine):"
echo "   ssh -i ~/.ssh/${AWS_KEY_NAME}.pem -L 3306:${RDS_ENDPOINT}:3306 ${SSH_USER}@${PUBLIC_IP}"
echo "   Then connect your local DB client to localhost:3306"
echo ""
echo "5. Configure DNS (if using custom domain):"
echo "   Create A record: ${DOMAIN} -> ${PUBLIC_IP}"
echo ""
echo "==============================================================================="
echo ""
echo "Security Group Note:"
echo "  Port 3306 is open FROM the security group TO itself (self-referencing)."
echo "  For RDS access, add this SG (${SG_ID}) as a source in your RDS security group"
echo "  inbound rule for port 3306 (MySQL/Aurora)."
echo ""
echo "To terminate this instance later:"
echo "  aws ec2 terminate-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
echo ""
echo "==============================================================================="

log "Provisioning complete!"