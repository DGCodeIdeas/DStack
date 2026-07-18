"""Unit tests for server/virtual_hosts.py.

These tests focus on the pure, side-effect-free parts of the module:
domain validation, template rendering, and parsing of a fake vhosts directory.
No Docker daemon or /etc/hosts writes are required, so they run anywhere.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

# Make the server package importable when running the file directly.
SERVER_DIR = Path(__file__).resolve().parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from virtual_hosts import (  # noqa: E402
    NGINX_VHOST_TEMPLATE,
    TRY_FILES_LARAVEL,
    TRY_FILES_PHP,
    VirtualHostManager,
    render_vhost,
    validate_domain,
)


# ---------------------------------------------------------------------------
# Domain validation
# ---------------------------------------------------------------------------
def test_validate_domain_accepts_valid():
    for domain in ["testapp.local", "api.example.com", "localhost", "a.b.c.d", "x-y.z"]:
        ok, err = validate_domain(domain)
        assert ok, f"expected {domain!r} valid, got error: {err}"


def test_validate_domain_rejects_bad():
    for domain in [
        "",
        None,
        123,
        "has space.local",
        "trailingdot.",
        "/etc/passwd",
        "..",
        "../escape",
        "a/../b",
    ]:
        ok, err = validate_domain(domain)
        assert not ok, f"expected {domain!r} invalid"


# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------
def test_render_vhost_php_contains_expected_directives():
    out = render_vhost("testapp.local", "/var/www/projects/testapp.local", framework="php")
    assert "server_name testapp.local;" in out
    assert "root /var/www/projects/testapp.local;" in out
    assert "listen 80;" in out
    assert "index index.php index.html;" in out
    assert "fastcgi_pass php:9000;" in out
    assert "fastcgi_index index.php;" in out
    assert "include fastcgi_params;" in out
    assert "fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;" in out
    # PHP framework uses =404 fallback, not the Laravel query string.
    assert TRY_FILES_PHP in out
    assert "index.php?$query_string" not in out
    # SSL placeholder is present and commented out.
    assert "listen 443 ssl;" in out


def test_render_vhost_laravel_uses_query_string():
    out = render_vhost(
        "laravel.app", "/var/www/projects/laravel.app/public", framework="laravel"
    )
    assert "server_name laravel.app;" in out
    assert "root /var/www/projects/laravel.app/public;" in out
    assert TRY_FILES_LARAVEL in out


def test_render_vhost_uses_provided_template():
    custom = "DOMAIN={domain} ROOT={container_root} TF={try_files}"
    out = render_vhost("x.local", "/r", framework="php", template=custom)
    assert out == "DOMAIN=x.local ROOT=/r TF=" + TRY_FILES_PHP


def test_template_is_valid_str_format():
    # The built-in template must be consumable by str.format with the 3 keys.
    rendered = NGINX_VHOST_TEMPLATE.format(
        domain="d", container_root="/r", try_files="try_files $uri;"
    )
    assert "server_name d;" in rendered
    # No leftover unescaped double braces in the rendered output.
    assert "{{" not in rendered and "}}" not in rendered


# ---------------------------------------------------------------------------
# list_all parsing against a fake vhosts directory
# ---------------------------------------------------------------------------
def _write_vhost(directory: Path, name: str, content: str) -> None:
    (directory / f"{name}.conf").write_text(content, encoding="utf-8")


def test_list_all_parses_php_and_laravel():
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        projects = Path(tmp) / "projects"
        projects.mkdir()

        php_conf = (
            "server {\n"
            "    server_name phpapp.local;\n"
            "    root /var/www/projects/phpapp.local;\n"
            "    location / { try_files $uri $uri/ =404; }\n"
            "}\n"
        )
        laravel_conf = (
            "server {\n"
            "    server_name lap.app;\n"
            "    root /var/www/projects/lap.app/public;\n"
            "    location / { try_files $uri $uri/ /index.php?$query_string; }\n"
            "}\n"
        )
        _write_vhost(vhosts, "phpapp.local", php_conf)
        _write_vhost(vhosts, "lap.app", laravel_conf)

        mgr = VirtualHostManager(root=tmp)
        # VirtualHostManager creates <root>/docker/vhosts; point it at our fake one.
        mgr.vhosts_dir = vhosts
        mgr.projects_host_dir = projects

        result = mgr.list_all()
        by_domain = {e["domain"]: e for e in result}

        assert set(by_domain) == {"phpapp.local", "lap.app"}

        php = by_domain["phpapp.local"]
        assert php["framework"] == "php"
        assert php["root"] == str(projects / "phpapp.local")
        assert php["config_path"].endswith("phpapp.local.conf")

        lara = by_domain["lap.app"]
        assert lara["framework"] == "laravel"
        assert lara["root"] == str(projects / "lap.app" / "public")


def test_list_all_empty_when_no_dir():
    with tempfile.TemporaryDirectory() as tmp:
        mgr = VirtualHostManager(root=tmp)
        mgr.vhosts_dir = Path(tmp) / "does-not-exist"
        assert mgr.list_all() == []


def test_list_all_falls_back_to_filename_when_no_server_name():
    with tempfile.TemporaryDirectory() as tmp:
        vhosts = Path(tmp) / "vhosts"
        vhosts.mkdir()
        (vhosts / "fallback.local.conf").write_text(
            "server { root /var/www/projects/fallback.local; }\n", encoding="utf-8"
        )
        mgr = VirtualHostManager(root=tmp)
        mgr.vhosts_dir = vhosts
        result = mgr.list_all()
        assert result[0]["domain"] == "fallback.local"


if __name__ == "__main__":
    # Allow running without pytest installed.
    if importlib.util.find_spec("pytest") is not None:
        import pytest

        sys.exit(pytest.main([__file__, "-v"]))
    print("pytest not available; running minimal assertions manually")
    test_validate_domain_accepts_valid()
    test_validate_domain_rejects_bad()
    test_render_vhost_php_contains_expected_directives()
    test_render_vhost_laravel_uses_query_string()
    test_render_vhost_uses_provided_template()
    test_template_is_valid_str_format()
    test_list_all_parses_php_and_laravel()
    test_list_all_empty_when_no_dir()
    test_list_all_falls_back_to_filename_when_no_server_name()
    print("All manual assertions passed.")
