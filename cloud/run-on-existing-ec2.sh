#!/usr/bin/env bash
# =============================================================================
# DStack Run on Existing EC2
# =============================================================================
# DEPRECATED: This script is now a thin wrapper around provision-ec2.sh --existing.
# Use the unified entry point instead:
#   bash cloud/provision-ec2.sh --existing --ip <PUBLIC_IP>
#   bash cloud/provision-ec2.sh --existing --tag <TAG>
# =============================================================================

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <PUBLIC_IP>"
    echo ""
    echo "This script is deprecated. Use the unified entry point:"
    echo "  bash cloud/provision-ec2.sh --existing --ip <PUBLIC_IP>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/provision-ec2.sh" --existing --ip "$1"