"""Unit-style tests for ServiceManager parsing logic.

These tests do not require Docker or a running daemon; they exercise the pure
parsing functions against representative ``docker compose ps`` output.

Run with::

    python3 server/test_services.py
"""

from __future__ import annotations

import json
from services import KNOWN_SERVICES, ServiceManager


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"FAILED: {message}")
    print(f"  ok: {message}")


def test_parse_ps_json_array() -> None:
    """Modern ``docker compose ps --format json`` emits a JSON array."""
    sample = json.dumps(
        [
            {
                "Name": "devstack-nginx",
                "Service": "nginx",
                "State": "running",
                "Status": "Up 2 hours",
                "Health": "",
            },
            {
                "Name": "devstack-mysql",
                "Service": "mysql",
                "State": "running",
                "Status": "Up 5 minutes (healthy)",
                "Health": "healthy",
            },
            {
                "Name": "devstack-redis",
                "Service": "redis",
                "State": "exited",
                "Status": "Exited (0) 10 minutes ago",
                "Health": "",
            },
        ]
    )
    result = ServiceManager.parse_ps_output(sample)

    _assert(set(result.keys()) == {"nginx", "mysql", "redis"}, "all three services parsed")
    _assert(result["nginx"]["state"] == "running", "nginx state running")
    _assert(result["nginx"]["status"] == "Up 2 hours", "nginx status text")
    _assert(result["nginx"]["health"] is None, "nginx health empty -> None")
    _assert(result["mysql"]["health"] == "healthy", "mysql health from Health field")
    _assert(result["redis"]["state"] == "exited", "redis state exited")


def test_parse_ps_json_line_delimited() -> None:
    """Some versions emit one JSON object per line."""
    lines = "\n".join(
        [
            json.dumps({"Service": "php", "State": "running", "Status": "Up 1 hour"}),
            json.dumps({"Service": "phpmyadmin", "State": "running", "Status": "Up 1 hour"}),
        ]
    )
    result = ServiceManager.parse_ps_output(lines)
    _assert(set(result.keys()) == {"php", "phpmyadmin"}, "line-delimited parsed")
    _assert(result["php"]["state"] == "running", "php running")


def _aligned_table() -> str:
    """Build a column-aligned table that mimics real ``docker compose ps``."""
    headers = ["NAME", "IMAGE", "COMMAND", "SERVICE", "STATUS", "PORTS"]
    widths = [22, 16, 24, 12, 28, 24]
    rows = [
        ["devstack-nginx", "nginx:latest", '"/docker-entrypoint.…"', "nginx", "Up 2 hours", "0.0.0.0:80->80/tcp"],
        ["devstack-mysql", "mysql:8.0", '"/docker-entrypoint.s…"', "mysql", "Up 5 minutes (healthy)", "0.0.0.0:3306->3306/tcp"],
        ["devstack-redis", "redis:alpine", '"/docker-entrypoint.s…"', "redis", "Exited (0) 10 minutes ago", ""],
    ]

    def _fmt(cols):
        return "".join(col.ljust(w) for col, w in zip(cols, widths))

    return "\n".join([_fmt(headers)] + [_fmt(r) for r in rows])


def test_parse_ps_text_table() -> None:
    """Fallback for the default human-readable table format."""
    result = ServiceManager.parse_ps_text(_aligned_table())
    _assert(set(result.keys()) == {"nginx", "mysql", "redis"}, "table services parsed")
    _assert(result["nginx"]["state"] == "running", "nginx running from text")
    _assert(result["mysql"]["health"] == "healthy", "mysql health parsed from parens")
    _assert(result["redis"]["state"] == "exited", "redis exited from text")


def test_parse_empty() -> None:
    _assert(ServiceManager.parse_ps_output("") == {}, "empty string -> empty dict")
    _assert(ServiceManager.parse_ps_output("   \n  ") == {}, "whitespace -> empty dict")


def test_known_services_constant() -> None:
    all_cmd = ServiceManager()._action_command("up", "all")
    _assert("all" not in all_cmd, "all target omits service arg")
    redis_cmd = ServiceManager()._action_command("stop", "redis")
    _assert(redis_cmd[-1] == "redis", "service arg appended for non-all")
    _assert(KNOWN_SERVICES == {"nginx", "php", "mysql", "phpmyadmin", "redis", "all"}, "known set correct")


def main() -> None:
    print("Running ServiceManager parsing tests...")
    test_parse_ps_json_array()
    test_parse_ps_json_line_delimited()
    test_parse_ps_text_table()
    test_parse_empty()
    test_known_services_constant()
    print("\nAll tests passed.")


if __name__ == "__main__":
    main()
