"""Service manager for the DevStack Docker Compose stack.

Provides a thin, testable wrapper around ``docker compose`` (v2) with a
fallback to the legacy ``docker-compose`` (v1) CLI. All subprocess calls are
bounded by a timeout and never raise on expected failures (missing binary,
unavailable daemon, non-zero exit); instead they return a structured result.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

# Services defined in docker/docker-compose.yml plus the "all" pseudo-target.
KNOWN_SERVICES = {"nginx", "php", "mysql", "phpmyadmin", "redis", "all"}

# Default timeout (seconds) for any docker subprocess invocation.
DEFAULT_TIMEOUT = 60


class ServiceManager:
    """Manage the lifecycle and status of the DevStack compose services."""

    def __init__(self, root: str | Path | None = None, timeout: int = DEFAULT_TIMEOUT):
        # Project root is the parent of the ``server`` package directory.
        self.root = Path(root).resolve() if root else Path(__file__).resolve().parent.parent
        self.compose_file = self.root / "docker" / "docker-compose.yml"
        self.env_file = self._resolve_env_file()
        self.timeout = timeout
        self.docker_cmd = self._detect_docker_command()

    # ------------------------------------------------------------------
    # Setup / discovery helpers
    # ------------------------------------------------------------------
    def _resolve_env_file(self) -> Path:
        """Prefer ``<root>/.env``; fall back to ``<root>/.env.example``."""
        env = self.root / ".env"
        if env.is_file():
            return env
        example = self.root / ".env.example"
        if example.is_file():
            return example
        # Default to ``.env`` even if missing so callers can surface a clear error.
        return env

    def _detect_docker_command(self) -> list[str]:
        """Return the docker compose invocation to use.

        Prefers the v2 plugin (``docker compose``) and falls back to the
        standalone v1 binary (``docker-compose``). If neither is available we
        still return a best-guess command; the resulting ``FileNotFoundError``
        is handled gracefully at execution time.
        """
        if shutil.which("docker") and self._can_run(["docker", "compose", "version"]):
            return ["docker", "compose"]
        if shutil.which("docker-compose") and self._can_run(["docker-compose", "version"]):
            return ["docker-compose"]
        if shutil.which("docker"):
            return ["docker", "compose"]
        if shutil.which("docker-compose"):
            return ["docker-compose"]
        return ["docker", "compose"]

    @staticmethod
    def _can_run(cmd: list[str]) -> bool:
        try:
            subprocess.run(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
            return True
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            return False

    # ------------------------------------------------------------------
    # Command building
    # ------------------------------------------------------------------
    def _base_command(self) -> list[str]:
        """Build the common prefix shared by every compose invocation."""
        cmd = list(self.docker_cmd)
        cmd += ["--env-file", str(self.env_file)]
        cmd += ["-f", str(self.compose_file)]
        return cmd

    def _action_command(self, compose_action: str, service: str, extra: list[str] | None = None) -> list[str]:
        """Assemble the full command for start/stop/restart."""
        cmd = self._base_command() + [compose_action]
        if extra:
            cmd += extra
        if service != "all":
            cmd += [service]
        return cmd

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------
    def _run(self, cmd: list[str]) -> dict:
        """Run a command, returning a structured result.

        Returns ``{"success": bool, "message": str, "stdout": str, "stderr": str}``.
        """
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
    # Public API
    # ------------------------------------------------------------------
    def get_all_status(self) -> dict:
        """Return status of all services keyed by service name.

        On failure (e.g. daemon unavailable) returns ``{"error": "<msg>"}``
        instead of raising.
        """
        cmd = self._base_command() + ["ps", "--format", "json"]
        result = self._run(cmd)
        if not result["success"]:
            return {"error": result["message"]}

        parsed = self.parse_ps_output(result["stdout"])
        # Fall back to the human-readable table format if JSON was unavailable
        # or produced no parseable entries.
        if not parsed and result["stdout"].strip():
            parsed = self.parse_ps_text(result["stdout"])
        return parsed

    def start(self, service: str = "all") -> dict:
        """Start ``service`` (or all services) in detached mode."""
        return self._execute("up", service, extra=["-d"])

    def stop(self, service: str = "all") -> dict:
        """Stop ``service`` (or all services)."""
        return self._execute("stop", service)

    def restart(self, service: str = "all") -> dict:
        """Restart ``service`` (or all services)."""
        return self._execute("restart", service)

    def _execute(self, compose_action: str, service: str, extra: list[str] | None = None) -> dict:
        if service not in KNOWN_SERVICES:
            return {
                "success": False,
                "message": (
                    f"Unknown service {service!r}. "
                    f"Valid services: {sorted(KNOWN_SERVICES)}"
                ),
            }
        cmd = self._action_command(compose_action, service, extra=extra)
        return self._run(cmd)

    # ------------------------------------------------------------------
    # Output parsing (pure functions, easy to unit test)
    # ------------------------------------------------------------------
    @staticmethod
    def parse_ps_output(raw: str) -> dict:
        """Parse ``docker compose ps --format json`` output.

        Handles both a single JSON array and newline-delimited JSON objects.
        Returns a dict keyed by service name with ``status``, ``state`` and
        ``health``.
        """
        raw = (raw or "").strip()
        if not raw:
            return {}

        entries: list[dict] = []
        try:
            data = json.loads(raw)
            entries = data if isinstance(data, list) else [data]
        except json.JSONDecodeError:
            for line in raw.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue

        return ServiceManager._entries_to_status(entries)

    @staticmethod
    def parse_ps_text(raw: str) -> dict:
        """Best-effort parser for the default ``docker compose ps`` table.

        Columns are located by their *positions* in the header row (the output
        is fixed-width aligned), so multi-word STATUS values such as
        ``Up 5 minutes (healthy)`` are preserved instead of being split on
        whitespace.
        """
        lines = (raw or "").strip().splitlines()
        if len(lines) < 2:
            return {}

        header_line = lines[0]
        # Map each header token to its starting column index.
        columns: list[tuple[str, int]] = []
        cursor = 0
        for token in header_line.split():
            start = header_line.index(token, cursor)
            columns.append((token.upper(), start))
            cursor = start + len(token)

        pos = {name: start for name, start in columns}
        if "SERVICE" not in pos or "STATUS" not in pos:
            return {}

        def _slice(line: str, name: str) -> str:
            start = pos[name]
            end = None
            for _, s in columns:
                if s > start:
                    end = s
                    break
            return line[start:end].strip()

        entries: list[dict] = []
        for line in lines[1:]:
            if not line.strip():
                continue
            name = _slice(line, "SERVICE")
            if name:
                entries.append({"Service": name, "Status": _slice(line, "STATUS")})

        return ServiceManager._entries_to_status(entries)

    @staticmethod
    def _entries_to_status(entries: list[dict]) -> dict:
        status: dict[str, dict] = {}
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            name = entry.get("Service") or entry.get("Name")
            if not name:
                continue
            raw_status = (entry.get("Status") or "").strip()
            state = entry.get("State")
            if not state and raw_status:
                # Derive a simple state from the status text when absent.
                lowered = raw_status.lower()
                if lowered.startswith("up"):
                    state = "running"
                elif lowered.startswith("exited"):
                    state = "exited"
                elif lowered.startswith("paused"):
                    state = "paused"
                elif lowered.startswith("restarting"):
                    state = "restarting"
                else:
                    state = "unknown"
            health = entry.get("Health")
            if not health and "(" in raw_status and ")" in raw_status:
                # e.g. "Up 2 hours (healthy)"
                health = raw_status[raw_status.rfind("(") + 1: raw_status.rfind(")")]
            status[name] = {
                "status": raw_status or None,
                "state": state or None,
                "health": health or None,
            }
        return status


if __name__ == "__main__":
    import pprint

    pprint.pprint(ServiceManager().get_all_status())
