"""Unit tests for the logs aggregator and its Flask endpoints.

These tests do not require Docker or a running daemon. They exercise:
  * service/target validation,
  * the pure log-line parser,
  * command-building (argv assembly),
  * graceful structured errors when the daemon/subprocess fails,
  * the streaming generator with a faked ``Popen``.

Run with::

    python3 server/test_logs.py
"""

from __future__ import annotations

import subprocess
from types import SimpleNamespace

import logs_aggregator as la
from logs_aggregator import (
    KNOWN_SERVICES,
    VALID_TARGETS,
    LogAggregator,
    build_logs_command,
    coerce_lines,
    parse_log_line,
    parse_logs_output,
)


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"FAILED: {message}")
    print(f"  ok: {message}")


# ---------------------------------------------------------------------------
# 1. Service / target validation
# ---------------------------------------------------------------------------
def test_validation() -> None:
    agg = LogAggregator()
    for svc in KNOWN_SERVICES:
        _assert(agg.is_valid_target(svc), f"known service accepted: {svc}")
    _assert(agg.is_valid_target("all"), "pseudo-target 'all' accepted")
    for bad in {"", "nginx ", "NGINX", "postgres", "foo", None}:
        _assert(not agg.is_valid_target(bad), f"invalid target rejected: {bad!r}")
    _assert(
        VALID_TARGETS == KNOWN_SERVICES | {"all"},
        "VALID_TARGETS == KNOWN_SERVICES | {'all'}",
    )


# ---------------------------------------------------------------------------
# 2. Parser
# ---------------------------------------------------------------------------
_SAMPLE = "\n".join(
    [
        "nginx-1  | 192.168.1.1 - - [18/Jul/2026:19:00:00 +0000] \"GET / HTTP/1.1\" 200",
        "php-1    | PHP Deprecated: ... in /var/www/index.php on line 10",
        "mysql-1  | 2026-07-18T19:00:01.123456Z 0 [System] [MY-010116] Server startup",
        "redis-1  | 1:M 18 Jul 2026 19:00:02.000 * Ready to accept connections",
        "phpmyadmin-1  | [info] serving on :8080",
        "this line has no pipe separator so it is treated as a bare message",
    ]
)


def test_parse_logs_output() -> None:
    entries = parse_logs_output(_SAMPLE)
    _assert(len(entries) == 6, "six lines parsed")

    # Container index suffix is stripped from the service name.
    _assert(entries[0]["service"] == "nginx", "nginx-1 -> nginx")
    _assert(entries[1]["service"] == "php", "php-1 -> php")
    _assert(entries[2]["service"] == "mysql", "mysql-1 -> mysql")
    _assert(entries[3]["service"] == "redis", "redis-1 -> redis")
    _assert(entries[4]["service"] == "phpmyadmin", "phpmyadmin-1 -> phpmyadmin")

    # The message keeps the text after the pipe, leading space trimmed.
    _assert(
        entries[0]["message"].startswith('192.168.1.1 - - [18/Jul/2026'),
        "nginx message preserved",
    )

    # A line without the ' | ' shape is kept whole with service=None.
    bare = entries[5]
    _assert(bare["service"] is None, "bare line has service=None")
    _assert(
        bare["message"] == "this line has no pipe separator so it is treated as a bare message",
        "bare line message == raw",
    )

    # parse_log_line works on a single line too.
    single = parse_log_line("nginx-1  | hello")
    _assert(single == {"raw": "nginx-1  | hello", "service": "nginx", "message": "hello"},
            "parse_log_line single line")


def test_parse_empty() -> None:
    _assert(parse_logs_output("") == [], "empty string -> empty list")
    _assert(parse_logs_output("   \n  ") == [], "whitespace -> empty list")


# ---------------------------------------------------------------------------
# 3. Command building
# ---------------------------------------------------------------------------
def test_build_logs_command() -> None:
    base = ["docker", "compose", "--env-file", ".env", "-f", "docker/docker-compose.yml"]

    # Snapshot for a single service with --tail and --no-color.
    cmd = build_logs_command(base, "nginx", lines=100, follow=False, no_color=True)
    _assert(
        cmd == base + ["logs", "--no-color", "--tail", "100", "nginx"],
        "snapshot command for nginx matches expected argv",
    )

    # 'all' omits the service argument.
    cmd_all = build_logs_command(base, "all", lines=50, follow=False, no_color=True)
    _assert(cmd_all[-1] != "all", "'all' target omits service arg")
    _assert(cmd_all == base + ["logs", "--no-color", "--tail", "50"], "all target argv")

    # Follow mode uses -f and no --tail.
    cmd_f = build_logs_command(base, "redis", lines=None, follow=True, no_color=True)
    _assert(cmd_f == base + ["logs", "--no-color", "-f", "redis"], "follow command argv")

    # no_color=False drops the flag.
    cmd_c = build_logs_command(base, "php", lines=10, follow=False, no_color=False)
    _assert(cmd_c == base + ["logs", "--tail", "10", "php"], "color kept when no_color=False")


def test_coerce_lines() -> None:
    _assert(coerce_lines(100) == 100, "int passthrough")
    _assert(coerce_lines("100") == 100, "string int parsed")
    _assert(coerce_lines("abc") == 50, "garbage -> default")
    _assert(coerce_lines(0) == 1, "below min clamped to 1")
    _assert(coerce_lines(999999) == 5000, "above max clamped to 5000")


# ---------------------------------------------------------------------------
# 4. get_logs graceful error when the daemon/subprocess fails
# ---------------------------------------------------------------------------
def test_get_logs_filenotfound() -> None:
    agg = LogAggregator()
    original = subprocess.run

    def _fake_run(*args, **kwargs):
        raise FileNotFoundError("docker not found")

    subprocess.run = _fake_run
    try:
        result = agg.get_logs("nginx", lines=10)
    finally:
        subprocess.run = original

    _assert(result["success"] is False, "FileNotFoundError -> success False")
    _assert("Docker" in result["message"] or "not found" in result["message"].lower(),
            "message mentions missing docker")
    _assert(result["lines"] == [] and result["raw"] == "", "empty lines/raw on error")
    _assert(result["service"] == "nginx", "service echoed back")


def test_get_logs_nonzero_exit() -> None:
    agg = LogAggregator()
    original = subprocess.run

    class _FakeProc:
        returncode = 1
        stdout = ""
        stderr = "error during connect: this error is specific to the daemon"

    def _fake_run(*args, **kwargs):
        return _FakeProc()

    subprocess.run = _fake_run
    try:
        result = agg.get_logs("all", lines=5)
    finally:
        subprocess.run = original

    _assert(result["success"] is False, "non-zero exit -> success False")
    _assert("daemon" in result["message"], "stderr surfaced in message")
    _assert(result["service"] == "all", "all echoed back")


def test_get_logs_unknown_service() -> None:
    agg = LogAggregator()
    result = agg.get_logs("postgres", lines=5)
    _assert(result["success"] is False, "unknown service -> success False")
    _assert("Unknown service" in result["message"], "message names unknown service")


# ---------------------------------------------------------------------------
# 5. stream_logs generator with a faked Popen
# ---------------------------------------------------------------------------
def test_stream_logs_yields_and_terminates() -> None:
    agg = LogAggregator()
    original_popen = subprocess.Popen

    fake_lines = [
        "nginx-1  | request 1\n",
        "nginx-1  | request 2\n",
        "php-1    | log line\n",
    ]

    terminated = {"called": False}

    class _FakeStdout:
        def __init__(self, lines):
            self._it = iter(lines)

        def readline(self):
            try:
                return next(self._it)
            except StopIteration:
                return ""

    class _FakeProc:
        def __init__(self):
            self.stdout = _FakeStdout(fake_lines)

        def terminate(self):
            terminated["called"] = True

        def wait(self, timeout=None):
            return 0

        def kill(self):
            terminated["called"] = True

    def _fake_popen(*args, **kwargs):
        return _FakeProc()

    subprocess.Popen = _fake_popen
    try:
        # Consume the generator fully.
        yielded = list(agg.stream_logs("nginx"))
    finally:
        subprocess.Popen = original_popen

    _assert(
        yielded == ["nginx-1  | request 1", "nginx-1  | request 2", "php-1    | log line"],
        "generator yields decoded, newline-stripped lines",
    )
    _assert(terminated["called"] is True, "terminate() called when generator closes")


def test_stream_logs_invalid_raises() -> None:
    agg = LogAggregator()
    raised = False
    try:
        # Iterating triggers the validation before any subprocess is spawned.
        list(agg.stream_logs("nope"))
    except ValueError:
        raised = True
    _assert(raised, "invalid service raises ValueError before streaming")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    print("Running logs_aggregator tests...")
    test_validation()
    test_parse_logs_output()
    test_parse_empty()
    test_build_logs_command()
    test_coerce_lines()
    test_get_logs_filenotfound()
    test_get_logs_nonzero_exit()
    test_get_logs_unknown_service()
    test_stream_logs_yields_and_terminates()
    test_stream_logs_invalid_raises()
    print("\nAll logs tests passed.")


if __name__ == "__main__":
    main()
