"""Logs aggregation for the DevStack Docker Compose stack.

Provides a thin, testable wrapper around ``docker compose logs`` (v2) with a
fallback to the legacy ``docker-compose`` (v1) CLI. Command building reuses the
exact same resolution logic as :class:`services.ServiceManager` (env-file
resolution, compose-file resolution, v2->v1 detection) so the two stay
consistent.

All subprocess calls are bounded by a timeout and never raise on expected
failures (missing binary, unavailable daemon, non-zero exit); instead they
return a structured result. The streaming API is a generator that yields each
log line as it arrives and guarantees the underlying process is terminated when
the generator is closed.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

from services import ServiceManager

# Services defined in docker/docker-compose.yml.
KNOWN_SERVICES = {"nginx", "php", "mysql", "redis", "phpmyadmin"}
# "all" is a pseudo-target meaning "every service".
VALID_TARGETS = KNOWN_SERVICES | {"all"}

# Default timeout (seconds) for any docker subprocess invocation.
DEFAULT_TIMEOUT = 60
# Default number of trailing lines to fetch.
DEFAULT_LINES = 50
# Guard against absurd/abusive values coming from the API.
MAX_LINES = 5000
MIN_LINES = 1


# ---------------------------------------------------------------------------
# Pure helpers (no daemon required -> easy to unit test)
# ---------------------------------------------------------------------------
# ``docker compose logs`` emits one line per entry in the form:
#     <service>[-<index>]  | <message>
# e.g. ``nginx-1  | 192.168.1.1 - - [...] "GET / HTTP/1.1" 200``
_LOG_LINE_RE = re.compile(r"^(?P<service>\S+)\s+\|\s?(?P<message>.*)$")


def _strip_container_index(service: str) -> str:
    """Turn ``nginx-1`` into ``nginx``; leave plain names untouched."""
    parts = service.rsplit("-", 1)
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0]
    return service


def parse_log_line(line: str) -> dict:
    """Parse a single ``docker compose logs`` line.

    Returns ``{"raw", "service", "message"}``. ``service`` is ``None`` when the
    line does not match the ``name | message`` shape (e.g. a continuation line
    or pre-formatted output).
    """
    line = line.rstrip("\n")
    match = _LOG_LINE_RE.match(line)
    if match:
        service = _strip_container_index(match.group("service"))
        return {
            "raw": line,
            "service": service,
            "message": match.group("message"),
        }
    return {"raw": line, "service": None, "message": line}


def parse_logs_output(raw: str) -> list[dict]:
    """Parse a full ``docker compose logs`` blob into a list of entries.

    Blank/whitespace-only lines are skipped so callers don't receive empty
    entries for trailing newlines or interleaved blank lines.
    """
    if not raw:
        return []
    return [
        parse_log_line(line)
        for line in raw.splitlines()
        if line.strip()
    ]


def build_logs_command(
    base_cmd: list[str],
    service: str,
    lines: int | None = DEFAULT_LINES,
    follow: bool = False,
    no_color: bool = True,
) -> list[str]:
    """Assemble the ``docker compose logs`` argv from a base command.

    ``base_cmd`` is the prefix produced by ``ServiceManager._base_command()``
    (docker binary + env-file + compose-file flags). This is a pure function so
    it can be unit tested without a daemon.
    """
    cmd = list(base_cmd)
    cmd += ["logs"]
    if no_color:
        cmd += ["--no-color"]
    if follow:
        cmd += ["-f"]
    if not follow and lines is not None:
        cmd += ["--tail", str(lines)]
    if service != "all":
        cmd += [service]
    return cmd


def coerce_lines(value, default: int = DEFAULT_LINES) -> int:
    """Coerce an arbitrary ``lines`` value into a safe positive int."""
    try:
        lines = int(value)
    except (TypeError, ValueError):
        return default
    if lines < MIN_LINES:
        return MIN_LINES
    if lines > MAX_LINES:
        return MAX_LINES
    return lines


# ---------------------------------------------------------------------------
# Aggregator
# ---------------------------------------------------------------------------
class LogAggregator:
    """Fetch and stream logs for the DevStack compose services."""

    def __init__(self, root: str | Path | None = None, timeout: int = DEFAULT_TIMEOUT):
        # Reuse ServiceManager for env/compose resolution and v2->v1 detection
        # so command building is identical to the rest of the app.
        self._manager = ServiceManager(root=root, timeout=timeout)
        self.root = self._manager.root
        self.compose_file = self._manager.compose_file
        self.env_file = self._manager.env_file
        self.timeout = timeout
        self.docker_cmd = self._manager.docker_cmd

    # ------------------------------------------------------------------
    # Command building
    # ------------------------------------------------------------------
    def _base_cmd(self) -> list[str]:
        """Common prefix shared by every compose invocation."""
        return self._manager._base_command()

    def _logs_command(self, service: str, lines: int, follow: bool) -> list[str]:
        return build_logs_command(
            self._base_cmd(), service, lines=lines, follow=follow, no_color=True
        )

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------
    @staticmethod
    def is_valid_target(service: str) -> bool:
        return service in VALID_TARGETS

    # ------------------------------------------------------------------
    # Snapshot fetch
    # ------------------------------------------------------------------
    def get_logs(self, service: str, lines: int = DEFAULT_LINES) -> dict:
        """Return the last ``lines`` log lines for ``service`` (or all).

        On any failure (unknown service, missing daemon, timeout, non-zero
        exit) returns a structured ``{"success": False, ...}`` dict rather than
        raising, so callers (and the web UI) can render a clean error.
        """
        if not self.is_valid_target(service):
            return {
                "success": False,
                "message": (
                    f"Unknown service {service!r}. "
                    f"Valid targets: {sorted(VALID_TARGETS)}"
                ),
                "service": service,
                "lines": [],
                "entries": [],
                "raw": "",
                "truncated": False,
            }

        lines = coerce_lines(lines)
        cmd = self._logs_command(service, lines, follow=False)

        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=self.timeout,
                cwd=str(self.root),
            )
        except FileNotFoundError:
            return {
                "success": False,
                "message": f"Command not found: {cmd[0]!r}. Is Docker installed?",
                "service": service,
                "lines": [],
                "entries": [],
                "raw": "",
                "truncated": False,
            }
        except subprocess.TimeoutExpired:
            return {
                "success": False,
                "message": f"Command timed out after {self.timeout}s: {' '.join(cmd)}",
                "service": service,
                "lines": [],
                "entries": [],
                "raw": "",
                "truncated": False,
            }
        except OSError as exc:
            return {
                "success": False,
                "message": f"OS error running command: {exc}",
                "service": service,
                "lines": [],
                "entries": [],
                "raw": "",
                "truncated": False,
            }

        raw = proc.stdout or ""
        if proc.returncode != 0:
            detail = (proc.stderr or raw).strip() or f"Command failed (exit {proc.returncode})"
            return {
                "success": False,
                "message": detail,
                "service": service,
                "lines": [],
                "entries": [],
                "raw": raw,
                "truncated": False,
            }

        entries = parse_logs_output(raw)
        line_strings = [entry["raw"] for entry in entries]
        # With --tail N the output is inherently capped; surface a heuristic so
        # the UI can indicate the log was truncated to the requested window.
        truncated = bool(lines) and len(line_strings) >= lines
        return {
            "success": True,
            "message": "OK",
            "service": service,
            "lines": line_strings,
            "entries": entries,
            "raw": raw,
            "truncated": truncated,
        }

    # ------------------------------------------------------------------
    # Streaming
    # ------------------------------------------------------------------
    def stream_logs(self, service: str):
        """Yield log lines for ``service`` in real time (``docker compose logs -f``).

        This is a generator. It validates the service first (raising
        ``ValueError`` for an unknown target) and then streams decoded lines as
        they arrive. The underlying process is always terminated in a
        ``finally`` block, so closing the generator (or breaking early) cleans
        up the subprocess.
        """
        if not self.is_valid_target(service):
            raise ValueError(
                f"Unknown service {service!r}. "
                f"Valid targets: {sorted(VALID_TARGETS)}"
            )

        cmd = self._logs_command(service, lines=None, follow=True)
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(self.root),
        )
        try:
            for line in iter(proc.stdout.readline, ""):
                if not line:
                    break
                yield line.rstrip("\n")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    import pprint

    pprint.pprint(LogAggregator().get_logs("nginx"))
