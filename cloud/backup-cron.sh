#!/usr/bin/env bash
# DevStack Manager - Scheduled Database Backup
#
# This script is intended to be run via cron to create periodic database backups.
# It invokes the BackupManager CLI directly (no Flask server required).
#
# Recommended crontab entry (runs daily at 03:00 UTC):
#   0 3 * * * /path/to/DStack/cloud/backup-cron.sh >> /var/log/devstack-backup.log 2>&1
#
# Adjust the path and schedule as needed. Ensure the cron user has:
#   - Access to the Docker daemon (docker group or sudo)
#   - Read access to the project's .env file (DB_ROOT_PASSWORD, etc.)
#   - Write access to <project_root>/backups/
#
# The script changes to the project root so all paths resolve correctly
# regardless of the cron working directory.

set -euo pipefail

# Resolve the project root (parent of this script's directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional: load a dedicated cron env file if it exists (e.g. for DB_ROOT_PASSWORD).
# This allows keeping secrets out of the main .env if desired.
if [[ -f "${PROJECT_ROOT}/.env.cron" ]]; then
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/.env.cron"
fi

# Also load the main .env so DB_ROOT_PASSWORD etc. are available to the Python script.
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/.env"
fi

# Change to project root so BackupManager resolves paths correctly.
cd "${PROJECT_ROOT}"

# Timestamp for log prefix.
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "[${TS}] Starting scheduled backup..."

# Run the backup via the BackupManager CLI.
# --description "scheduled" tags the manifest so you can filter later.
# The CLI prints JSON to stdout; we capture it for logging.
if OUTPUT=$(python3 "${PROJECT_ROOT}/server/backup_restore.py" backup --description "scheduled" 2>&1); then
    echo "[${TS}] Backup completed successfully."
    echo "${OUTPUT}"
    exit 0
else
    EXIT_CODE=$?
    echo "[${TS}] Backup FAILED (exit ${EXIT_CODE})."
    echo "${OUTPUT}"
    exit "${EXIT_CODE}"
fi