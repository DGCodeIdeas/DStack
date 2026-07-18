"""DevStack Manager - Flask backend.

Exposes a small REST API to inspect and control the Docker Compose services
defined in ``docker/docker-compose.yml`` and serves the (future) web UI static
files from ``../web-ui``.

Run with::

    python3 server/app.py

The server binds to ``0.0.0.0`` on the port from ``APP_PORT`` (default 5000).
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from flask import (
    Flask,
    jsonify,
    request,
    Response,
    send_from_directory,
    stream_with_context,
)
from flask_cors import CORS

from services import KNOWN_SERVICES, ServiceManager
from virtual_hosts import VirtualHostManager, validate_domain
from ssl_manager import SSLManager
from rds_tunnel import RDSTunnel
from logs_aggregator import LogAggregator, VALID_TARGETS
from backup_restore import BackupManager
from backup_restore import BackupManager

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# server/app.py -> project root is the parent directory.
SERVER_DIR = Path(__file__).resolve().parent
ROOT_DIR = SERVER_DIR.parent
WEBUI_DIR = ROOT_DIR / "web-ui"

# ---------------------------------------------------------------------------
# Configuration (everything comes from the environment)
# ---------------------------------------------------------------------------
# Load env files in order of precedence. load_dotenv does not override already
# set variables, so the first existing file wins for each key.
load_dotenv(ROOT_DIR / ".env")
load_dotenv(SERVER_DIR / ".env")
load_dotenv(ROOT_DIR / ".env.example")

APP_PORT = int(os.getenv("APP_PORT", "5000"))
FLASK_DEBUG = os.getenv("FLASK_DEBUG", "").lower() in {"1", "true", "yes"}

# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------
app = Flask(
    __name__,
    static_folder=str(WEBUI_DIR) if WEBUI_DIR.is_dir() else None,
    static_url_path="/assets",
)
CORS(app)

# Reuse a single ServiceManager instance across requests.
_manager = ServiceManager()

# Reuse a single VirtualHostManager instance across requests.
_vhost_manager = VirtualHostManager()

# Reuse a single SSLManager instance across requests.
_ssl_manager = SSLManager()

# Reuse a single RDSTunnel instance across requests so start/stop/status
# share the same tunnel state.
_rds_tunnel = RDSTunnel()

# Reuse a single LogAggregator instance across requests so command resolution
# (env-file, compose-file, v2->v1 detection) is consistent with ServiceManager.
_log_aggregator = LogAggregator()

# Reuse a single BackupManager instance across requests so backups are written
# to a consistent location and share the same docker/compose discovery.
_backup_manager = BackupManager()


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------
@app.get("/api/health")
def health():
    """Liveness probe."""
    return jsonify({"status": "ok"})


@app.get("/api/services")
def services():
    """Return the status of every compose service."""
    return jsonify(_manager.get_all_status())


@app.post("/api/services/<service>/<action>")
def service_action(service: str, action: str):
    """Start, stop or restart a service (or ``all``)."""
    if service not in KNOWN_SERVICES:
        return (
            jsonify(
                {
                    "success": False,
                    "message": (
                        f"Unknown service {service!r}. "
                        f"Valid: {sorted(KNOWN_SERVICES)}"
                    ),
                    "status": None,
                }
            ),
            400,
        )

    if action not in {"start", "stop", "restart"}:
        return (
            jsonify(
                {
                    "success": False,
                    "message": f"Unknown action {action!r}. Valid: start, stop, restart",
                    "status": None,
                }
            ),
            400,
        )

    handler = getattr(_manager, action)
    result = handler(service)
    status = _manager.get_all_status() if result.get("success") else None
    return jsonify(
        {
            "success": result.get("success", False),
            "message": result.get("message", ""),
            "status": status,
        }
    )


# ---------------------------------------------------------------------------
# Virtual hosts
# ---------------------------------------------------------------------------
@app.get("/api/vhosts")
def list_vhosts():
    """List all configured virtual hosts."""
    return jsonify(_vhost_manager.list_all())


@app.post("/api/vhosts")
def create_vhost():
    """Create a virtual host from ``{domain, root?, framework?}``."""
    data = request.get_json(silent=True) or {}
    domain = data.get("domain")
    ok, err = validate_domain(domain)
    if not ok:
        return jsonify({"success": False, "message": err, "domain": domain}), 400

    framework = data.get("framework", "php")
    if framework not in {"php", "laravel"}:
        return (
            jsonify(
                {
                    "success": False,
                    "message": "framework must be 'php' or 'laravel'",
                    "domain": domain,
                }
            ),
            400,
        )

    result = _vhost_manager.create(domain, root=data.get("root"), framework=framework)
    status = 200 if result.get("success") else 400
    return jsonify(result), status


@app.delete("/api/vhosts/<domain>")
def delete_vhost(domain: str):
    """Delete a virtual host. 404 if no config exists for ``domain``."""
    ok, err = validate_domain(domain)
    if not ok:
        return jsonify({"success": False, "message": err, "domain": domain}), 400

    result = _vhost_manager.delete(domain)
    if not result.get("success") and result.get("missing"):
        return jsonify(result), 404
    return jsonify(result)


# ---------------------------------------------------------------------------
# SSL certificates
# ---------------------------------------------------------------------------
@app.get("/api/ssl")
@app.get("/api/ssl/certs")
def list_certs():
    """List all certificates found in the ssl directory."""
    return jsonify(_ssl_manager.list_certs())


@app.post("/api/ssl/local")
def create_ssl_local():
    """Create a locally-trusted (mkcert) certificate for ``{domain}``."""
    data = request.get_json(silent=True) or {}
    domain = data.get("domain")
    ok, err = validate_domain(domain)
    if not ok:
        return jsonify({"success": False, "message": err, "domain": domain}), 400
    result = _ssl_manager.create_mkcert(domain)
    status = 200 if result.get("success") else 400
    return jsonify(result), status


@app.post("/api/ssl/letsencrypt")
def create_ssl_letsencrypt():
    """Create a Let's Encrypt certificate for ``{domain, email}``."""
    data = request.get_json(silent=True) or {}
    domain = data.get("domain")
    email = data.get("email")
    ok, err = validate_domain(domain)
    if not ok:
        return jsonify({"success": False, "message": err, "domain": domain}), 400
    if not email or "@" not in str(email):
        return (
            jsonify(
                {
                    "success": False,
                    "message": "A valid 'email' is required for Let's Encrypt",
                    "domain": domain,
                }
            ),
            400,
        )
    mode = data.get("mode", "standalone")
    webroot_path = data.get("webroot_path")
    result = _ssl_manager.create_letsencrypt(domain, email, mode=mode, webroot_path=webroot_path)
    status = 200 if result.get("success") else 400
    return jsonify(result), status


# ---------------------------------------------------------------------------
# RDS SSH tunnel (local <-> EC2 <-> RDS)
# ---------------------------------------------------------------------------
@app.post("/api/rds/tunnel/start")
def rds_tunnel_start():
    """Open an SSH tunnel to a remote RDS endpoint via an EC2 bastion.

    Body: {ec2_host, ec2_user, ec2_key_path, rds_host,
           rds_port?, local_port?}
    """
    data = request.get_json(silent=True) or {}
    ec2_host = data.get("ec2_host")
    ec2_user = data.get("ec2_user")
    ec2_key_path = data.get("ec2_key_path")
    rds_host = data.get("rds_host")
    rds_port = data.get("rds_port", 3306)
    local_port = data.get("local_port", 3307)

    # Coerce ports to int when provided as strings; reject non-int coercible.
    try:
        rds_port = int(rds_port)
        local_port = int(local_port)
    except (TypeError, ValueError):
        return (
            jsonify(
                {
                    "success": False,
                    "message": "rds_port and local_port must be integers",
                    "local_port": local_port,
                    "rds_host": rds_host,
                    "rds_port": rds_port,
                }
            ),
            400,
        )

    # Server-side existence check for the key path (best effort).
    if ec2_key_path and not Path(ec2_key_path).expanduser().is_file():
        return (
            jsonify(
                {
                    "success": False,
                    "message": f"ec2_key_path does not exist: {ec2_key_path}",
                    "local_port": local_port,
                    "rds_host": rds_host,
                    "rds_port": rds_port,
                }
            ),
            400,
        )

    result = _rds_tunnel.connect(
        ec2_host=ec2_host,
        ec2_user=ec2_user,
        ec2_key_path=ec2_key_path,
        rds_host=rds_host,
        rds_port=rds_port,
        local_port=local_port,
    )
    status = 200 if result.get("success") else 400
    return jsonify(result), status


@app.post("/api/rds/tunnel/stop")
def rds_tunnel_stop():
    """Tear down the active RDS tunnel (safe even if not connected)."""
    result = _rds_tunnel.disconnect()
    return jsonify(result)


@app.get("/api/rds/tunnel/status")
def rds_tunnel_status():
    """Return the current RDS tunnel status."""
    return jsonify(_rds_tunnel.get_status())


# ---------------------------------------------------------------------------
# Logs aggregation
# ---------------------------------------------------------------------------
@app.get("/api/logs/<service>")
def get_logs(service: str):
    """Return the last N log lines for ``service`` (or ``all``).

    Query params:
      * ``lines``  - number of trailing lines (default 50, clamped 1..5000)
      * ``follow`` - if truthy, stream live logs instead of a snapshot

    Returns 400 for an unknown service. On daemon/subprocess failure the body
    still contains a clean ``{"success": false, ...}`` JSON (no crash).
    """
    if service not in VALID_TARGETS:
        return (
            jsonify(
                {
                    "success": False,
                    "message": (
                        f"Unknown service {service!r}. "
                        f"Valid: {sorted(VALID_TARGETS)}"
                    ),
                    "service": service,
                    "lines": [],
                    "raw": "",
                }
            ),
            400,
        )

    # Support live streaming via ?follow=1 on the same endpoint.
    if request.args.get("follow"):
        return Response(
            stream_with_context(_log_aggregator.stream_logs(service)),
            mimetype="text/plain; charset=utf-8",
        )

    try:
        lines = int(request.args.get("lines", 50))
    except (TypeError, ValueError):
        lines = 50

    result = _log_aggregator.get_logs(service, lines=lines)
    return jsonify(
        {
            "service": service,
            "lines": result.get("lines", []),
            "raw": result.get("raw", ""),
            "success": result.get("success", False),
            "message": result.get("message", ""),
            "truncated": result.get("truncated", False),
            "entries": result.get("entries", []),
        }
    )


@app.get("/api/logs/<service>/stream")
def stream_logs(service: str):
    """Stream live logs for ``service`` (or ``all``) as newline-delimited text.

    Returns 400 for an unknown service. The response is a streaming
    ``text/plain`` body so the web UI can render logs in real time.
    """
    if service not in VALID_TARGETS:
        return (
            jsonify(
                {
                    "success": False,
                    "message": (
                        f"Unknown service {service!r}. "
                        f"Valid: {sorted(VALID_TARGETS)}"
                    ),
                    "service": service,
                }
            ),
            400,
        )

    return Response(
        stream_with_context(_log_aggregator.stream_logs(service)),
        mimetype="text/plain; charset=utf-8",
    )


# ---------------------------------------------------------------------------
# Backup & Restore
# ---------------------------------------------------------------------------
@app.post("/api/backup")
def create_backup():
    """Create a database backup.

    Body: {database?: string, description?: string}
    - ``database`` defaults to "all" (all databases). Use a specific name to
      dump only that database. Basic sanitization: only [A-Za-z0-9_]+ allowed.
    - ``description`` is free-text stored in the manifest.
    """
    data = request.get_json(silent=True) or {}
    database = data.get("database", "all")
    description = data.get("description", "")

    if not BackupManager._validate_db_name(database):
        return (
            jsonify(
                {
                    "success": False,
                    "message": (
                        f"Invalid database name: {database!r}. "
                        "Use 'all' or a name matching [A-Za-z0-9_]+."
                    ),
                }
            ),
            400,
        )

    result = _backup_manager.backup(database=database, description=description)
    status = 200 if result.get("success") else 500
    return jsonify(result), status


@app.get("/api/backups")
def list_backups():
    """List all available backups, newest first."""
    return jsonify(_backup_manager.list_backups())


@app.post("/api/restore")
def restore_backup():
    """Restore a database backup.

    Body: {backup_id: string, database?: string}
    - ``backup_id`` is the timestamp directory name (e.g. "20260718_120000").
    - ``database`` is optional; if provided, restores into that specific
      database instead of the original one(s).
    """
    data = request.get_json(silent=True) or {}
    backup_id = data.get("backup_id")
    database = data.get("database")

    if not backup_id:
        return (
            jsonify({"success": False, "message": "backup_id is required"}),
            400,
        )

    if database is not None and not BackupManager._validate_db_name(database):
        return (
            jsonify(
                {
                    "success": False,
                    "message": (
                        f"Invalid database name: {database!r}. "
                        "Use a name matching [A-Za-z0-9_]+."
                    ),
                }
            ),
            400,
        )

    result = _backup_manager.restore(backup_id=backup_id, database=database)
    if result.get("missing"):
        return jsonify(result), 404
    status = 200 if result.get("success") else 500
    return jsonify(result), status


# ---------------------------------------------------------------------------
# Web UI (served once the files exist; guarded so the app still boots empty)
# ---------------------------------------------------------------------------
@app.get("/")
@app.get("/<path:filename>")
def serve_ui(filename: str = ""):
    """Serve the web-ui static files, falling back to index.html."""
    if not WEBUI_DIR.is_dir():
        return (
            jsonify(
                {
                    "error": "web-ui not built yet",
                    "hint": "Static files will be served from ../web-ui once present.",
                }
            ),
            404,
        )
    # Prevent path traversal: resolve and ensure it stays inside WEBUI_DIR.
    target = (WEBUI_DIR / filename).resolve()
    if filename and target.is_file() and str(target).startswith(str(WEBUI_DIR)):
        return send_from_directory(str(WEBUI_DIR), filename)
    # SPA-style fallback to index.html for client-side routing.
    index = WEBUI_DIR / "index.html"
    if index.is_file():
        return send_from_directory(str(WEBUI_DIR), "index.html")
    return jsonify({"error": "web-ui/index.html not found"}), 404


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=APP_PORT, debug=FLASK_DEBUG)
