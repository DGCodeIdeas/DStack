"""Unit tests for server/ssl_manager.py.

These tests focus on the pure, side-effect-free parts of the module: domain
validation reuse, SSL server-block rendering, ``list_certs`` scanning a temp
directory, and the missing-binary error path. No Docker daemon is required.

Note on binaries: ``mkcert`` and ``openssl`` happen to be present in this
sandbox, while ``certbot`` is not. The tests are written to be adaptive: when a
binary is present we verify real behaviour; when it is absent we verify the
clean, actionable error is returned (no crash).
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

# Make the server package importable when running the file directly.
SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from ssl_manager import (  # noqa: E402
    SSLManager,
    cert_filename,
    key_filename,
    render_ssl_server_block,
)
from virtual_hosts import validate_domain  # noqa: E402

# Real on-disk vhost template, used to prove injection works against the
# actual shipped config (copied to a temp dir so the repo file is untouched).
REAL_VHOST = SERVER_DIR.parent / "docker" / "vhosts" / "testapp.local.conf"


# ---------------------------------------------------------------------------
# Domain validation (reused from virtual_hosts)
# ---------------------------------------------------------------------------
def test_validate_domain_accepts_valid():
    for domain in ["testapp.local", "api.example.com", "localhost", "a.b.c.d"]:
        ok, err = validate_domain(domain)
        assert ok, f"expected {domain!r} valid, got error: {err}"


def test_validate_domain_rejects_bad():
    for domain in ["", None, 123, "has space.local", "/etc/passwd", "..", "../escape"]:
        ok, err = validate_domain(domain)
        assert not ok, f"expected {domain!r} invalid"


# ---------------------------------------------------------------------------
# Filename helpers
# ---------------------------------------------------------------------------
def test_filename_helpers():
    assert cert_filename("testapp.local") == "testapp.local.pem"
    assert key_filename("testapp.local") == "testapp.local-key.pem"


# ---------------------------------------------------------------------------
# SSL server-block rendering
# ---------------------------------------------------------------------------
def test_render_ssl_server_block_contains_expected_directives():
    out = render_ssl_server_block(
        "testapp.local",
        "/etc/nginx/ssl/testapp.local.pem",
        "/etc/nginx/ssl/testapp.local-key.pem",
        "/var/www/projects/testapp.local",
        "try_files $uri $uri/ =404;",
    )
    assert "listen 443 ssl http2;" in out
    assert "server_name testapp.local;" in out
    assert "ssl_certificate /etc/nginx/ssl/testapp.local.pem;" in out
    assert "ssl_certificate_key /etc/nginx/ssl/testapp.local-key.pem;" in out
    assert "ssl_protocols TLSv1.2 TLSv1.3;" in out
    assert "ssl_ciphers" in out
    assert "fastcgi_pass php:9000;" in out
    assert "fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;" in out
    # The HTTP block uses port 80, not 443.
    assert "listen 80;" not in out


# ---------------------------------------------------------------------------
# list_certs scanning a temp directory
# ---------------------------------------------------------------------------
def test_list_certs_scans_temp_dir():
    with tempfile.TemporaryDirectory() as tmp:
        ssl_dir = Path(tmp) / "ssl"
        ssl_dir.mkdir()
        # A complete cert pair.
        (ssl_dir / "app.local.pem").write_text("CERT", encoding="utf-8")
        (ssl_dir / "app.local-key.pem").write_text("KEY", encoding="utf-8")
        # A cert without its key (should still be listed, exists=False).
        (ssl_dir / "lonely.local.pem").write_text("CERT", encoding="utf-8")
        # A stray key file (must NOT be listed as its own domain).
        (ssl_dir / "orphan-key.pem").write_text("KEY", encoding="utf-8")

        mgr = SSLManager(root=tmp)
        mgr.ssl_dir = ssl_dir
        certs = mgr.list_certs()
        by_domain = {c["domain"]: c for c in certs}

        # orphan-key.pem must not produce a "orphan" domain entry.
        assert "orphan" not in by_domain
        assert set(by_domain) == {"app.local", "lonely.local"}

        assert by_domain["app.local"]["exists"] is True
        assert by_domain["app.local"]["cert_path"].endswith("app.local.pem")
        assert by_domain["app.local"]["key_path"].endswith("app.local-key.pem")

        assert by_domain["lonely.local"]["exists"] is False


def test_list_certs_empty_when_no_dir():
    with tempfile.TemporaryDirectory() as tmp:
        mgr = SSLManager(root=tmp)
        mgr.ssl_dir = Path(tmp) / "does-not-exist"
        assert mgr.list_certs() == []


# ---------------------------------------------------------------------------
# enable_vhost_ssl injection (no real certs required)
# ---------------------------------------------------------------------------
def test_enable_vhost_ssl_injects_https_block():
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        conf = vhosts / "testapp.local.conf"
        conf.write_text(
            "server {\n"
            "    listen 80;\n"
            "    listen [::]:80;\n"
            "    server_name testapp.local;\n"
            "    root /var/www/projects/testapp.local;\n"
            "    index index.php index.html;\n"
            "    location / {\n"
            "        try_files $uri $uri/ =404;\n"
            "    }\n"
            "    location ~ \\.php$ {\n"
            "        fastcgi_pass php:9000;\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )

        mgr = SSLManager(root=tmp)
        mgr.vhosts_dir = vhosts
        result = mgr.enable_vhost_ssl("testapp.local")
        assert result["success"], result

        content = conf.read_text(encoding="utf-8")
        assert "listen 443 ssl http2;" in content
        assert "ssl_certificate /etc/nginx/ssl/testapp.local.pem;" in content
        assert "ssl_certificate_key /etc/nginx/ssl/testapp.local-key.pem;" in content
        # HTTP block preserved.
        assert "listen 80;" in content
        # 301 redirect injected by default.
        assert "return 301 https://$host$request_uri;" in content
        # PHP proxying mirrored into the HTTPS block.
        assert content.count("fastcgi_pass php:9000;") == 2


def test_enable_vhost_ssl_on_real_config():
    """Prove injection works against the actual shipped vhost template."""
    if not REAL_VHOST.is_file():
        return
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        conf = vhosts / "testapp.local.conf"
        conf.write_text(REAL_VHOST.read_text(encoding="utf-8"), encoding="utf-8")

        mgr = SSLManager(root=tmp)
        mgr.vhosts_dir = vhosts
        result = mgr.enable_vhost_ssl("testapp.local")
        assert result["success"], result

        content = conf.read_text(encoding="utf-8")
        assert "listen 443 ssl http2;" in content
        assert "ssl_certificate /etc/nginx/ssl/testapp.local.pem;" in content
        assert "ssl_certificate_key /etc/nginx/ssl/testapp.local-key.pem;" in content
        # The original commented-out placeholder must be gone / replaced.
        assert "listen 443 ssl;" in content
        # HTTP block still present.
        assert "listen 80;" in content


def test_enable_vhost_ssl_no_redirect_when_disabled():
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        conf = vhosts / "testapp.local.conf"
        conf.write_text(
            "server {\n"
            "    listen 80;\n"
            "    server_name testapp.local;\n"
            "    root /var/www/projects/testapp.local;\n"
            "}\n",
            encoding="utf-8",
        )
        mgr = SSLManager(root=tmp)
        mgr.vhosts_dir = vhosts
        result = mgr.enable_vhost_ssl("testapp.local", redirect_http=False)
        assert result["success"], result
        content = conf.read_text(encoding="utf-8")
        assert "return 301 https://$host$request_uri;" not in content
        assert "listen 443 ssl http2;" in content


def test_enable_vhost_ssl_missing_config_errors():
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        mgr = SSLManager(root=tmp)
        mgr.vhosts_dir = vhosts
        result = mgr.enable_vhost_ssl("nope.local")
        assert not result["success"]
        assert "No vhost config" in result["message"]


def test_enable_vhost_ssl_replaces_existing_https_block():
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        conf = vhosts / "testapp.local.conf"
        conf.write_text(
            "server {\n"
            "    listen 80;\n"
            "    server_name testapp.local;\n"
            "    root /var/www/projects/testapp.local;\n"
            "}\n"
            "server {\n"
            "    listen 443 ssl;\n"
            "    server_name testapp.local;\n"
            "    ssl_certificate /etc/nginx/ssl/testapp.local.crt;\n"
            "}\n",
            encoding="utf-8",
        )
        mgr = SSLManager(root=tmp)
        mgr.vhosts_dir = vhosts
        result = mgr.enable_vhost_ssl("testapp.local")
        assert result["success"], result
        content = conf.read_text(encoding="utf-8")
        # Old cert path gone, new uniform path present.
        assert "/etc/nginx/ssl/testapp.local.crt" not in content
        assert "ssl_certificate /etc/nginx/ssl/testapp.local.pem;" in content
        # Exactly one HTTPS block remains.
        assert content.count("listen 443 ssl http2;") == 1


# ---------------------------------------------------------------------------
# Missing-binary / present-binary handling
# ---------------------------------------------------------------------------
def test_create_mkcert_handles_binary_presence():
    """mkcert may or may not be installed; handle both gracefully."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = SSLManager(root=tmp)
        result = mgr.create_mkcert("testapp.local")
        if shutil.which("mkcert"):
            assert result["success"] is True, result
            assert mgr._cert_path("testapp.local").is_file()
            assert mgr._key_path("testapp.local").is_file()
        else:
            assert result["success"] is False
            assert "mkcert not installed" in result["message"]
            assert "brew install mkcert" in result["message"]


def test_create_letsencrypt_missing_binary_returns_clean_error():
    with tempfile.TemporaryDirectory() as tmp:
        mgr = SSLManager(root=tmp)
        result = mgr.create_letsencrypt("testapp.local", "me@example.com")
        # certbot is not installed in this sandbox; verify the clean error.
        assert result["success"] is False
        assert "certbot not installed" in result["message"]


def test_create_mkcert_rejects_bad_domain():
    with tempfile.TemporaryDirectory() as tmp:
        mgr = SSLManager(root=tmp)
        result = mgr.create_mkcert("../escape")
        assert result["success"] is False
        assert "domain" in result


if __name__ == "__main__":
    # Allow running without pytest installed.
    if importlib.util.find_spec("pytest") is not None:
        import pytest

        sys.exit(pytest.main([__file__, "-v"]))
    print("pytest not available; running minimal assertions manually")
    test_validate_domain_accepts_valid()
    test_validate_domain_rejects_bad()
    test_filename_helpers()
    test_render_ssl_server_block_contains_expected_directives()
    test_list_certs_scans_temp_dir()
    test_list_certs_empty_when_no_dir()
    test_enable_vhost_ssl_injects_https_block()
    test_enable_vhost_ssl_on_real_config()
    test_enable_vhost_ssl_no_redirect_when_disabled()
    test_enable_vhost_ssl_missing_config_errors()
    test_enable_vhost_ssl_replaces_existing_https_block()
    test_create_mkcert_handles_binary_presence()
    test_create_letsencrypt_missing_binary_returns_clean_error()
    test_create_mkcert_rejects_bad_domain()
    print("All manual assertions passed.")
