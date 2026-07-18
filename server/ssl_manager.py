"""SSL certificate management for the DevStack Docker stack.

This module provides :class:`SSLManager`, a small, testable wrapper that
generates and manages TLS certificates for nginx virtual hosts. It supports two
issuance backends:

* **mkcert** (``create_mkcert``) - locally-trusted development certificates.
* **Let's Encrypt / certbot** (``create_letsencrypt``) - publicly-trusted
  certificates, intended for EC2 / production-like deployments.

In both cases the resulting certificate and key are normalised to a single,
uniform location on the host (``<root>/docker/ssl/<domain>.pem`` and
``<root>/docker/ssl/<domain>-key.pem``) which is bind-mounted read-only into
the nginx container at ``/etc/nginx/ssl`` (see ``docker/docker-compose.yml``).
This keeps the nginx ``ssl_certificate`` path identical regardless of which
issuer produced the cert.

All subprocess calls are bounded by a timeout and never raise on expected
failures (missing binary, unavailable daemon, non-zero exit); instead they
return a structured result, mirroring the graceful-degradation behaviour of
``server/services.py`` and ``server/virtual_hosts.py``.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

from services import ServiceManager
from virtual_hosts import NGINX_CONTAINER_NAME, validate_domain

# ---------------------------------------------------------------------------
# Constants (single source of truth for cert paths)
# ---------------------------------------------------------------------------
# Host-side directory (relative to the project root) where certificates live.
SSL_HOST_DIR_NAME = "ssl"

# Container-side directory the certs are mounted into (must match the volume
# mount in docker/docker-compose.yml: ./docker/ssl:/etc/nginx/ssl:ro).
SSL_CONTAINER_DIR = "/etc/nginx/ssl"

# Default timeout (seconds) for any certificate-generation subprocess.
DEFAULT_TIMEOUT = 120

# Modern TLS settings reused across every rendered HTTPS block.
SSL_PROTOCOLS = "TLSv1.2 TLSv1.3"
SSL_CIPHERS = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"

# Certbot live directory layout (root typically /etc/letsencrypt).
CERTBOT_LIVE_DIR = Path("/etc/letsencrypt/live")


# ---------------------------------------------------------------------------
# Pure helpers (easy to unit test)
# ---------------------------------------------------------------------------
def cert_filename(domain: str) -> str:
    """Host/container certificate file name for ``domain``."""
    return f"{domain}.pem"


def key_filename(domain: str) -> str:
    """Host/container private-key file name for ``domain``."""
    return f"{domain}-key.pem"


def render_ssl_server_block(
    domain: str,
    cert_path: str,
    key_path: str,
    root: str,
    try_files: str,
) -> str:
    """Render an nginx HTTPS ``server`` block for ``domain``.

    Pure function: given the same inputs it always returns the same string.
    ``cert_path`` / ``key_path`` are the *container-side* paths nginx reads
    (e.g. ``/etc/nginx/ssl/<domain>.pem``). ``root`` and ``try_files`` are
    reused from the existing HTTP block so PHP is proxied identically.
    """
    return (
        "server {\n"
        "    listen 443 ssl http2;\n"
        "    listen [::]:443 ssl http2;\n"
        f"    server_name {domain};\n"
        "\n"
        f"    ssl_certificate {cert_path};\n"
        f"    ssl_certificate_key {key_path};\n"
        "\n"
        f"    ssl_protocols {SSL_PROTOCOLS};\n"
        f"    ssl_ciphers {SSL_CIPHERS};\n"
        "    ssl_prefer_server_ciphers on;\n"
        "\n"
        f"    root {root};\n"
        "    index index.php index.html;\n"
        "\n"
        "    location / {\n"
        f"        {try_files}\n"
        "    }\n"
        "\n"
        "    location ~ \\.php$ {\n"
        "        fastcgi_pass php:9000;\n"
        "        fastcgi_index index.php;\n"
        "        include fastcgi_params;\n"
        "        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\n"
        "    }\n"
        "}\n"
    )


def _extract_server_blocks(content: str) -> list[tuple[int, int, str]]:
    """Return ``(start, end, block_text)`` for every ``server { ... }`` block.

    Brace counting handles nested blocks (e.g. ``location ~ \\.php$ { ... }``)
    so the returned spans are always complete server blocks.
    """
    blocks: list[tuple[int, int, str]] = []
    n = len(content)
    i = 0
    while True:
        m = re.search(r"server\s*\{", content[i:])
        if not m:
            break
        start = i + m.start()
        brace_start = i + m.end() - 1  # index of the opening '{'
        depth = 0
        j = brace_start
        while j < n:
            ch = content[j]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        end = j + 1
        blocks.append((start, end, content[start:end]))
        i = end
    return blocks


def _remove_https_server_block(content: str) -> str:
    """Remove any existing ``server`` block that listens on 443 (HTTPS).

    Only a *real* (uncommented) ``listen 443`` directive counts; the commented
    placeholder ``# listen 443 ssl;`` inside the HTTP block is ignored.
    """
    blocks = _extract_server_blocks(content)
    # Iterate in reverse so removing earlier spans does not shift later ones.
    for start, end, block in reversed(blocks):
        if re.search(r"^\s*listen\s+443", block, re.MULTILINE):
            content = content[:start] + content[end:]
    return content


def _inject_http_redirect(content: str, domain: str) -> str:
    """Add a 301 redirect to HTTPS inside the HTTP (``listen 80``) block.

    Inserts ``return 301 https://$host$request_uri;`` immediately after the
    block's ``server_name`` directive so every request is redirected before
    reaching the location handlers.
    """
    blocks = _extract_server_blocks(content)
    for start, end, block in blocks:
        is_http = re.search(r"^\s*listen\s+80\b", block, re.MULTILINE)
        is_https = re.search(r"^\s*listen\s+443", block, re.MULTILINE)
        if is_http and not is_https:
            # Only modify the block whose server_name matches the domain.
            sn = re.search(r"server_name\s+([^;]+);", block)
            if sn and domain in sn.group(1).split():
                redirect = "        return 301 https://$host$request_uri;"
                new_block = re.sub(
                    r"(server_name\s+[^\n]+;\n)",
                    lambda m: m.group(1) + redirect + "\n",
                    block,
                    count=1,
                )
                content = content[:start] + new_block + content[end:]
                break
    return content


# ---------------------------------------------------------------------------
# Manager
# ---------------------------------------------------------------------------
class SSLManager:
    """Create, list and wire up TLS certificates for DevStack vhosts."""

    def __init__(self, root: str | Path | None = None, timeout: int = DEFAULT_TIMEOUT):
        # Project root is the parent of the ``server`` package directory.
        self.root = Path(root).resolve() if root else Path(__file__).resolve().parent.parent
        self.ssl_dir = self.root / "docker" / SSL_HOST_DIR_NAME
        self.vhosts_dir = self.root / "docker" / "vhosts"
        self.nginx_container = NGINX_CONTAINER_NAME
        self.timeout = timeout
        # Ensure the ssl directory exists so writes never fail on a missing dir.
        self.ssl_dir.mkdir(parents=True, exist_ok=True)
        self.vhosts_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Path helpers (single place to change the container mount path)
    # ------------------------------------------------------------------
    def _cert_path(self, domain: str) -> Path:
        """Host-side certificate path."""
        return self.ssl_dir / cert_filename(domain)

    def _key_path(self, domain: str) -> Path:
        """Host-side private-key path."""
        return self.ssl_dir / key_filename(domain)

    def _container_cert_path(self, domain: str) -> str:
        """Container-side certificate path (what nginx reads)."""
        return f"{SSL_CONTAINER_DIR}/{cert_filename(domain)}"

    def _container_key_path(self, domain: str) -> str:
        """Container-side private-key path (what nginx reads)."""
        return f"{SSL_CONTAINER_DIR}/{key_filename(domain)}"

    # ------------------------------------------------------------------
    # Subprocess execution (graceful, never raises on expected failures)
    # ------------------------------------------------------------------
    def _run(self, cmd: list[str]) -> dict:
        """Run ``cmd``, returning a structured result.

        Returns ``{"success": bool, "message": str, "stdout": str, "stderr": str}``.
        """
        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=self.timeout,
            )
        except FileNotFoundError:
            return {
                "success": False,
                "message": f"Command not found: {cmd[0]!r}. Is it installed?",
                "stdout": "",
                "stderr": "",
            }
        except subprocess.TimeoutExpired:
            return {
                "success": False,
                "message": f"Command timed out after {self.timeout}s: {' '.join(cmd)}",
                "stdout": "",
                "stderr": "",
            }
        except OSError as exc:
            return {
                "success": False,
                "message": f"OS error running command: {exc}",
                "stdout": "",
                "stderr": "",
            }

        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        if proc.returncode != 0:
            detail = (stderr or stdout).strip() or f"Command failed (exit {proc.returncode})"
            return {
                "success": False,
                "message": detail,
                "stdout": stdout,
                "stderr": stderr,
            }
        return {
            "success": True,
            "message": stdout.strip() or "OK",
            "stdout": stdout,
            "stderr": stderr,
        }

    # ------------------------------------------------------------------
    # nginx reload (best-effort, never raises)
    # ------------------------------------------------------------------
    def _reload_nginx(self) -> list[str]:
        """Reload nginx inside the container. Returns warning strings on failure."""
        warnings: list[str] = []
        try:
            sm = ServiceManager(root=self.root)
            cmd = sm.docker_cmd + [
                "-f", str(sm.compose_file),
                "exec", self.nginx_container,
                "nginx", "-s", "reload",
            ]
            result = sm._run(cmd)
            if not result.get("success"):
                warnings.append(f"nginx reload failed: {result.get('message')}")
        except Exception as exc:  # noqa: BLE001 - best effort
            warnings.append(f"nginx reload could not be attempted: {exc}")
        return warnings

    # ------------------------------------------------------------------
    # mkcert (local development certificates)
    # ------------------------------------------------------------------
    def create_mkcert(self, domain: str) -> dict:
        """Generate a locally-trusted certificate for ``domain`` via mkcert.

        On success the certificate is wired into the vhost (``enable_vhost_ssl``)
        and a structured success result is returned. If ``mkcert`` is not
        installed a clean, actionable error is returned (no crash).
        """
        ok, err = validate_domain(domain)
        if not ok:
            return {"success": False, "domain": domain, "message": err}

        if not shutil.which("mkcert"):
            return {
                "success": False,
                "domain": domain,
                "message": (
                    "mkcert not installed. Install via "
                    "'brew install mkcert' / 'sudo apt install mkcert' "
                    "then run 'mkcert -install'"
                ),
            }

        cert_path = self._cert_path(domain)
        key_path = self._key_path(domain)
        # Include localhost / 127.0.0.1 as SANs so the dev machine can also hit
        # the host directly.
        cmd = [
            "mkcert",
            "-cert-file", str(cert_path),
            "-key-file", str(key_path),
            domain,
            "localhost",
            "127.0.0.1",
        ]
        result = self._run(cmd)
        if not result["success"]:
            return {
                "success": False,
                "domain": domain,
                "cert_path": str(cert_path),
                "key_path": str(key_path),
                "message": f"mkcert failed: {result['message']}",
            }

        # Wire the cert into the vhost config.
        enable = self.enable_vhost_ssl(domain)
        warnings = enable.get("warnings", [])
        return {
            "success": True,
            "domain": domain,
            "cert_path": str(cert_path),
            "key_path": str(key_path),
            "message": f"Certificate created for {domain} via mkcert",
            "vhost_enabled": enable.get("success", False),
            "warnings": warnings,
        }

    # ------------------------------------------------------------------
    # Let's Encrypt / certbot (publicly-trusted certificates)
    # ------------------------------------------------------------------
    def create_letsencrypt(
        self,
        domain: str,
        email: str,
        mode: str = "standalone",
        webroot_path: str | None = None,
    ) -> dict:
        """Issue a Let's Encrypt certificate for ``domain`` via certbot.

        ``mode`` is either ``"standalone"`` (default, stops nginx on 80/443) or
        ``"webroot"`` (requires ``webroot_path``). The issued ``fullchain.pem``
        and ``privkey.pem`` are copied into the uniform DevStack ssl dir so the
        nginx config path is identical to mkcert-issued certs.
        """
        ok, err = validate_domain(domain)
        if not ok:
            return {"success": False, "domain": domain, "message": err}

        if not email or "@" not in email:
            return {
                "success": False,
                "domain": domain,
                "message": "A valid 'email' is required for Let's Encrypt registration",
            }

        if not shutil.which("certbot"):
            return {
                "success": False,
                "domain": domain,
                "message": (
                    "certbot not installed. Install via "
                    "'sudo apt install certbot' (or 'certbot-nginx') "
                    "then retry. On EC2 ensure ports 80/443 are open."
                ),
            }

        if mode == "webroot":
            if not webroot_path:
                return {
                    "success": False,
                    "domain": domain,
                    "message": "webroot mode requires 'webroot_path'",
                }
            cmd = [
                "certbot", "certonly", "--webroot",
                "-w", webroot_path,
                "-d", domain,
                "-m", email,
                "--agree-tos", "--non-interactive",
            ]
        else:  # standalone
            cmd = [
                "certbot", "certonly", "--standalone",
                "-d", domain,
                "-m", email,
                "--agree-tos", "--non-interactive",
            ]

        result = self._run(cmd)
        if not result["success"]:
            return {
                "success": False,
                "domain": domain,
                "message": f"certbot failed: {result['message']}",
            }

        # Copy certbot's live certs into the uniform DevStack ssl dir.
        live_dir = CERTBOT_LIVE_DIR / domain
        src_cert = live_dir / "fullchain.pem"
        src_key = live_dir / "privkey.pem"
        cert_path = self._cert_path(domain)
        key_path = self._key_path(domain)
        try:
            shutil.copy(str(src_cert), str(cert_path))
            shutil.copy(str(src_key), str(key_path))
        except OSError as exc:
            return {
                "success": False,
                "domain": domain,
                "cert_path": str(cert_path),
                "key_path": str(key_path),
                "message": (
                    f"certbot issued the cert but copying from {live_dir} failed: {exc}. "
                    f"Run with privileges so /etc/letsencrypt is readable."
                ),
            }

        enable = self.enable_vhost_ssl(domain)
        warnings = enable.get("warnings", [])
        return {
            "success": True,
            "domain": domain,
            "cert_path": str(cert_path),
            "key_path": str(key_path),
            "message": f"Certificate created for {domain} via Let's Encrypt",
            "vhost_enabled": enable.get("success", False),
            "warnings": warnings,
        }

    # ------------------------------------------------------------------
    # Vhost SSL block injection
    # ------------------------------------------------------------------
    def enable_vhost_ssl(self, domain: str, redirect_http: bool = True) -> dict:
        """Inject (or replace) an HTTPS server block into the vhost config.

        Reads ``<vhosts_dir>/<domain>.conf``; if missing returns an error. The
        existing HTTP ``listen 80`` block is preserved. When ``redirect_http``
        is True a 301 redirect to HTTPS is added to the HTTP block. The PHP
        proxying is mirrored from the HTTP block so behaviour is identical.
        """
        ok, err = validate_domain(domain)
        if not ok:
            return {"success": False, "domain": domain, "message": err}

        config_path = self.vhosts_dir / f"{domain}.conf"
        if not config_path.is_file():
            return {
                "success": False,
                "domain": domain,
                "config_path": str(config_path),
                "message": f"No vhost config found at {config_path}",
            }

        try:
            content = config_path.read_text(encoding="utf-8")
        except OSError as exc:
            return {
                "success": False,
                "domain": domain,
                "config_path": str(config_path),
                "message": f"Could not read vhost config: {exc}",
            }

        # Extract root + try_files from the existing HTTP block.
        root_m = re.search(r"^\s*root\s+([^;]+);", content, re.MULTILINE)
        root = root_m.group(1).strip() if root_m else "/var/www/projects/" + domain
        tf_m = re.search(r"^\s*location\s+/\s*\{", content, re.MULTILINE)
        try_files = "try_files $uri $uri/ =404;"
        if tf_m:
            # Capture the try_files directive inside the location / block.
            block_start = tf_m.end()
            # Find the matching closing brace (no nesting inside location /).
            close = content.find("}", block_start)
            inner = content[block_start:close]
            tf = re.search(r"try_files\s+[^;]+;", inner)
            if tf:
                try_files = tf.group(0)

        # Remove any pre-existing HTTPS block, then append a fresh one.
        content = _remove_https_server_block(content)
        https_block = render_ssl_server_block(
            domain,
            self._container_cert_path(domain),
            self._container_key_path(domain),
            root,
            try_files,
        )
        # Ensure a blank line separates the blocks.
        if not content.endswith("\n"):
            content += "\n"
        content = content.rstrip("\n") + "\n\n" + https_block

        # Optionally add the 301 redirect to the HTTP block.
        if redirect_http:
            content = _inject_http_redirect(content, domain)

        try:
            config_path.write_text(content, encoding="utf-8")
        except OSError as exc:
            return {
                "success": False,
                "domain": domain,
                "config_path": str(config_path),
                "message": f"Could not write vhost config: {exc}",
            }

        warnings = self._reload_nginx()
        return {
            "success": True,
            "domain": domain,
            "config_path": str(config_path),
            "redirect_http": redirect_http,
            "message": f"HTTPS server block enabled for {domain}",
            "warnings": warnings,
        }

    # ------------------------------------------------------------------
    # Listing / status
    # ------------------------------------------------------------------
    def list_certs(self) -> list[dict]:
        """Scan the ssl dir for certificate files.

        Returns a list of ``{domain, cert_path, key_path, exists}``. A cert is
        considered present when both the ``.pem`` and ``-key.pem`` files exist.
        ``*-key.pem`` files are excluded from the domain scan to avoid double
        counting.
        """
        results: list[dict] = []
        if not self.ssl_dir.is_dir():
            return results

        for cert in sorted(self.ssl_dir.glob("*.pem")):
            name = cert.name
            if name.endswith("-key.pem"):
                continue  # key files are tracked via their cert
            domain = name[: -len(".pem")]
            key = self.ssl_dir / f"{domain}-key.pem"
            results.append({
                "domain": domain,
                "cert_path": str(cert),
                "key_path": str(key),
                "exists": cert.is_file() and key.is_file(),
            })
        return results

    def get_cert_status(self, domain: str) -> dict:
        """Return best-effort status for ``domain``'s certificate.

        Checks file existence and, when ``openssl`` is available, parses the
        not-after date to report expiry. Falls back to file existence only if
        openssl is missing.
        """
        ok, err = validate_domain(domain)
        if not ok:
            return {"success": False, "domain": domain, "message": err}

        cert_path = self._cert_path(domain)
        key_path = self._key_path(domain)
        if not cert_path.is_file() or not key_path.is_file():
            return {
                "success": False,
                "domain": domain,
                "cert_path": str(cert_path),
                "key_path": str(key_path),
                "exists": False,
                "message": "Certificate files not found",
            }

        status: dict = {
            "success": True,
            "domain": domain,
            "cert_path": str(cert_path),
            "key_path": str(key_path),
            "exists": True,
            "expired": None,
            "not_after": None,
        }

        if shutil.which("openssl"):
            result = self._run([
                "openssl", "x509", "-enddate", "-noout", "-in", str(cert_path),
            ])
            if result["success"]:
                m = re.search(r"notAfter=(.+)", result["stdout"])
                if m:
                    not_after = m.group(1).strip()
                    status["not_after"] = not_after
                    try:
                        from datetime import datetime, timezone
                        # openssl date format: Mmm DD HH:MM:SS YYYY GMT (UTC).
                        dt = datetime.strptime(not_after, "%b %d %H:%M:%S %Y %Z").replace(
                            tzinfo=timezone.utc
                        )
                        status["expired"] = dt < datetime.now(timezone.utc)
                    except (ValueError, ImportError):
                        status["expired"] = None
        else:
            status["message"] = "openssl not available; checked file existence only"

        return status


if __name__ == "__main__":
    import pprint

    pprint.pprint(SSLManager().list_certs())
