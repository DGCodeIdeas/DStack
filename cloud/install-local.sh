#!/usr/bin/env bash
# DevStack Manager - Local Installation Script
# One-command local setup for Kubuntu (and compatible distros).
# Usage: ./cloud/install-local.sh [--preflight] [--help]
#   --preflight  Only check prerequisites and print a status report; make no changes.
#   --help       Show this help and exit.
#
# Environment variables:
#   DSTACK_DIR        Target directory for the repo (default: ~/devstack-manager)
#   GITHUB_REPO_URL   GitHub repo URL to clone if not already in repo (default: https://github.com/dgi-dev/DStack.git)
#   DISPLAY           If set and xdg-open available, open dashboard in browser after install.
#   SKIP_BROWSER=1    Skip browser launch even if DISPLAY is set.

set -euo pipefail

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_FILE="${ROOT_DIR}/devstack.log"

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
info()   { echo -e "${BLUE}[INFO]${RESET} $*" | tee -a "${LOG_FILE}"; }
ok()     { echo -e "${GREEN}[ OK ]${RESET} $*" | tee -a "${LOG_FILE}"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*" | tee -a "${LOG_FILE}"; }
error()  { echo -e "${RED}[ERR ]${RESET} $*" | tee -a "${LOG_FILE}"; }
die()    { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Help / usage
# -----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
DevStack Manager - Local Installation Script

Usage: ./cloud/install-local.sh [--preflight] [--help]

Options:
  --preflight   Only check prerequisites and print a status report; make no changes.
  --help        Show this help and exit.

Environment variables:
  DSTACK_DIR        Target directory for the repo (default: ~/devstack-manager)
  GITHUB_REPO_URL   GitHub repo URL to clone if not already in repo (default: https://github.com/dgi-dev/DStack.git)
  DISPLAY           If set and xdg-open is available, open dashboard in browser after install.
  SKIP_BROWSER=1    Skip browser launch even if DISPLAY is set.

Examples:
  ./cloud/install-local.sh --preflight
  ./cloud/install-local.sh
  DSTACK_DIR=~/my-devstack ./cloud/install-local.sh
EOF
}

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
PREFLIGHT=0
CRITICAL_FAIL=0
OPTIONAL_FAIL=0

check_cmd() {
    local cmd="$1"
    local name="${2:-$1}"
    local version_flag="${3:---version}"
    local min_version="${4:-}"
    local hint="${5:-}"

    if command -v "$cmd" >/dev/null 2>&1; then
        local version=""
        if [[ -n "$min_version" ]]; then
            version=$("$cmd" $version_flag 2>/dev/null | head -n1 || true)
        fi
        ok "$name: found ($version)"
        return 0
    else
        error "$name: NOT FOUND"
        if [[ -n "$hint" ]]; then
            warn "  Hint: $hint"
        fi
        return 1
    fi
}

check_docker_daemon() {
    if docker info >/dev/null 2>&1; then
        ok "Docker daemon: reachable"
        return 0
    else
        error "Docker daemon: NOT REACHABLE"
        warn "  Hint: Start Docker daemon (sudo systemctl start docker) or ensure user is in 'docker' group."
        return 1
    fi
}

check_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        local ver=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null | head -n1)
        ok "docker compose (v2): found ($ver)"
        return 0
    elif command -v docker-compose >/dev/null 2>&1; then
        local ver=$(docker-compose --version 2>/dev/null | head -n1)
        ok "docker-compose (v1): found ($ver)"
        warn "  Note: docker-compose v1 is deprecated; consider upgrading to 'docker compose' (v2)."
        return 0
    else
        error "docker compose / docker-compose: NOT FOUND"
        warn "  Hint: Install Docker Compose v2 (docker compose) or v1 (docker-compose)."
        return 1
    fi
}

check_python_version() {
    if command -v python3 >/dev/null 2>&1; then
        local ver=$(python3 --version 2>&1 | awk '{print $2}')
        local major=$(echo "$ver" | cut -d. -f1)
        local minor=$(echo "$ver" | cut -d. -f2)
        if [[ "$major" -ge 3 && "$minor" -ge 10 ]]; then
            ok "python3: found ($ver) >= 3.10"
            return 0
        else
            error "python3: found ($ver) but need >= 3.10"
            warn "  Hint: Install Python 3.10+ (sudo apt install python3.10 python3.10-venv)"
            return 1
        fi
    else
        error "python3: NOT FOUND"
        warn "  Hint: Install Python 3.10+ (sudo apt install python3.10 python3.10-venv)"
        return 1
    fi
}

check_pip_venv() {
    local ok_flag=0
    if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
        ok "pip: available"
        ok_flag=1
    else
        warn "pip: NOT FOUND (optional but recommended)"
        warn "  Hint: Install pip (sudo apt install python3-pip)"
    fi
    if python3 -m venv --help >/dev/null 2>&1; then
        ok "venv: available"
        ok_flag=1
    else
        warn "venv: NOT AVAILABLE (optional but recommended)"
        warn "  Hint: Install python3-venv (sudo apt install python3.10-venv)"
    fi
    return $ok_flag
}

run_preflight() {
    log "=== DevStack Manager - Preflight Check ==="
    echo

    # Critical checks
    check_cmd docker docker "version" "" "Install Docker (https://docs.docker.com/engine/install/ubuntu/)" || CRITICAL_FAIL=1
    check_docker_daemon || CRITICAL_FAIL=1
    check_docker_compose || CRITICAL_FAIL=1
    check_cmd git git "" "" "Install git (sudo apt install git)" || CRITICAL_FAIL=1
    check_python_version || CRITICAL_FAIL=1

    # Optional checks
    check_cmd mkcert mkcert "" "" "Install mkcert (https://github.com/FiloSottile/mkcert) for local HTTPS" || OPTIONAL_FAIL=1
    check_pip_venv || OPTIONAL_FAIL=1

    echo
    log "=== Preflight Summary ==="
    if [[ $CRITICAL_FAIL -eq 0 ]]; then
        ok "All critical prerequisites: OK"
    else
        error "Critical prerequisites: MISSING (see above)"
    fi
    if [[ $OPTIONAL_FAIL -eq 0 ]]; then
        ok "Optional prerequisites: OK"
    else
        warn "Optional prerequisites: SOME MISSING (see above)"
    fi

    if [[ $CRITICAL_FAIL -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Main installation flow
# -----------------------------------------------------------------------------
main() {
    # Parse args
    for arg in "$@"; do
        case "$arg" in
            --preflight)
                PREFLIGHT=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $arg. Use --help for usage."
                ;;
        esac
    done

    if [[ $PREFLIGHT -eq 1 ]]; then
        run_preflight
        return
    fi

    log "=== DevStack Manager - Local Installation ==="
    echo

    # -------------------------------------------------------------------------
    # 1. Detect / clone repo
    # -------------------------------------------------------------------------
    local target_dir="${DSTACK_DIR:-$HOME/devstack-manager}"
    local repo_url="${GITHUB_REPO_URL:-https://github.com/dgi-dev/DStack.git}"

    if [[ -f "${ROOT_DIR}/docker/docker-compose.yml" ]]; then
        log "Running from inside the repository at ${ROOT_DIR}"
        TARGET_DIR="${ROOT_DIR}"
    else
        log "Repository not found in current directory. Target: ${target_dir}"
        if [[ -d "${target_dir}/.git" ]]; then
            log "Repository already exists at ${target_dir}, pulling latest..."
            git -C "${target_dir}" pull --ff-only
        else
            log "Cloning ${repo_url} into ${target_dir}..."
            git clone "${repo_url}" "${target_dir}"
        fi
        TARGET_DIR="${target_dir}"
        cd "${TARGET_DIR}"
        ROOT_DIR="${TARGET_DIR}"
        LOG_FILE="${ROOT_DIR}/devstack.log"
    fi

    # -------------------------------------------------------------------------
    # 2. .env file
    # -------------------------------------------------------------------------
    if [[ ! -f "${ROOT_DIR}/.env" ]]; then
        if [[ -f "${ROOT_DIR}/.env.example" ]]; then
            log "Creating .env from .env.example..."
            cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
            warn "IMPORTANT: Edit ${ROOT_DIR}/.env and set secure passwords before production use!"
        else
            warn ".env.example not found; skipping .env creation."
        fi
    else
        log ".env already exists; leaving as-is."
    fi

    # -------------------------------------------------------------------------
    # 3. Build and start Docker Compose services
    # -------------------------------------------------------------------------
    log "Building Docker images..."
    docker compose -f "${ROOT_DIR}/docker/docker-compose.yml" build

    log "Starting Docker Compose services..."
    docker compose -f "${ROOT_DIR}/docker/docker-compose.yml" up -d

    # Wait for services to be healthy
    log "Waiting for services to become healthy (timeout 120s)..."
    local timeout=120
    local elapsed=0
    local interval=5
    while [[ $elapsed -lt $timeout ]]; do
        local all_healthy=1
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
            if [[ "$line" =~ ^NAME ]]; then continue; fi
            local status=$(echo "$line" | awk '{print $NF}')
            if [[ "$status" != "healthy" && "$status" != "running" && "$status" != "exited(0)" ]]; then
                all_healthy=0
                break
            fi
        done < <(docker compose -f "${ROOT_DIR}/docker/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true)

        if [[ $all_healthy -eq 1 ]]; then
            ok "All services are healthy/running."
            break
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [[ $elapsed -ge $timeout ]]; then
        warn "Timeout waiting for all services to become healthy. Current status:"
        docker compose -f "${ROOT_DIR}/docker/docker-compose.yml" ps
    fi

    # -------------------------------------------------------------------------
    # 4. Projects directory
    # -------------------------------------------------------------------------
    log "Ensuring projects directory exists..."
    mkdir -p "${ROOT_DIR}/projects"

    # -------------------------------------------------------------------------
    # 5. mkcert CA install (best effort)
    # -------------------------------------------------------------------------
    if command -v mkcert >/dev/null 2>&1; then
        log "Installing mkcert local CA (best effort)..."
        if mkcert -install 2>&1 | tee -a "${LOG_FILE}"; then
            ok "mkcert CA installed."
        else
            warn "mkcert -install failed (may need libnss3-tools on Linux). Continuing..."
        fi
    else
        warn "mkcert not installed; skipping local CA install. HTTPS certs will not be auto-trusted."
    fi

    # -------------------------------------------------------------------------
    # 6. Start Flask dashboard (background)
    # -------------------------------------------------------------------------
    log "Starting Flask dashboard (server/app.py) in background..."
    cd "${ROOT_DIR}"
    nohup python3 server/app.py >> "${LOG_FILE}" 2>&1 &
    FLASK_PID=$!
    echo $FLASK_PID > "${ROOT_DIR}/.flask.pid"
    log "Flask PID: $FLASK_PID (logged to ${LOG_FILE})"

    # Wait for port 5000
    log "Waiting for Flask dashboard on port 5000..."
    local flask_timeout=30
    local flask_elapsed=0
    while [[ $flask_elapsed -lt $flask_timeout ]]; do
        if curl -s -f "http://localhost:5000/api/health" >/dev/null 2>&1; then
            ok "Flask dashboard is up on http://localhost:5000"
            break
        fi
        sleep 1
        flask_elapsed=$((flask_elapsed + 1))
    done
    if [[ $flask_elapsed -ge $flask_timeout ]]; then
        warn "Flask dashboard did not respond in time. Check ${LOG_FILE} for errors."
    fi

    # -------------------------------------------------------------------------
    # 7. Create initial test vhost
    # -------------------------------------------------------------------------
    log "Creating test virtual host (testapp.local)..."
    local vhost_resp=$(curl -s -X POST "http://localhost:5000/api/vhosts" \
        -H "Content-Type: application/json" \
        -d '{"domain":"testapp.local","framework":"php"}' 2>/dev/null || true)
    if echo "$vhost_resp" | grep -q '"success":true'; then
        ok "Test vhost created: testapp.local"
    elif echo "$vhost_resp" | grep -q 'already exists'; then
        ok "Test vhost already exists: testapp.local"
    else
        warn "Could not create test vhost (may already exist or API not ready): $vhost_resp"
    fi

    # -------------------------------------------------------------------------
    # 8. Output access URLs
    # -------------------------------------------------------------------------
    echo
    log "=== Access URLs ==="
    ok "Dashboard:        http://localhost:5000"
    ok "phpMyAdmin:       http://localhost:8080"
    ok "Test vhost:       http://testapp.local (add '127.0.0.1 testapp.local' to /etc/hosts if not auto-added)"
    echo
    log "API Endpoints:"
    ok "  Health:         http://localhost:5000/api/health"
    ok "  Services:       http://localhost:5000/api/services"
    ok "  VHosts:         http://localhost:5000/api/vhosts"
    ok "  SSL:            http://localhost:5000/api/ssl"
    ok "  Backups:        http://localhost:5000/api/backups"
    ok "  RDS Tunnel:     http://localhost:5000/api/rds/tunnel/status"
    ok "  Nginx Logs:     http://localhost:5000/api/logs/nginx?lines=20"
    echo

    # -------------------------------------------------------------------------
    # 9. Post-install verification
    # -------------------------------------------------------------------------
    log "=== Post-Install Verification ==="
    local endpoints=(
        "/api/health"
        "/api/services"
        "/api/vhosts"
        "/api/ssl"
        "/api/backups"
        "/api/rds/tunnel/status"
        "/api/logs/nginx?lines=20"
    )
    local pass=0
    local fail=0
    printf "%-35s %s\n" "ENDPOINT" "STATUS"
    printf "%-35s %s\n" "-----------------------------------" "------"
    for ep in "${endpoints[@]}"; do
        if curl -s -f "http://localhost:5000${ep}" >/dev/null 2>&1; then
            printf "%-35s ${GREEN}PASS${RESET}\n" "$ep"
            ((pass++))
        else
            printf "%-35s ${RED}FAIL${RESET}\n" "$ep"
            ((fail++))
        fi
    done
    echo
    ok "Passed: $pass, Failed: $fail"

    # -------------------------------------------------------------------------
    # 10. Optional browser launch
    # -------------------------------------------------------------------------
    if [[ -n "${DISPLAY:-}" && -z "${SKIP_BROWSER:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
        log "Opening dashboard in browser..."
        xdg-open "http://localhost:5000" >/dev/null 2>&1 &
    fi

    log "=== Installation Complete ==="
    log "Dashboard PID: $FLASK_PID (log: ${LOG_FILE})"
    log "To stop: kill $FLASK_PID && docker compose -f ${ROOT_DIR}/docker/docker-compose.yml down"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
main "$@"