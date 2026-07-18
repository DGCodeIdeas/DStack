"""Database backup & restore manager for the DevStack Docker Compose stack.

This module provides :class:`BackupManager`, a thin, testable wrapper around
``docker compose exec`` + ``mysqldump``/``mysql`` (with ``gzip`` compression).
All subprocess calls are bounded by a timeout and never raise on expected
failures (missing binary, unavailable daemon, non-zero exit); instead they
return a structured ``{"success": bool, "message": str, ...}`` result.

Design notes
------------
* The ``docker compose`` (v2) -> ``docker-compose`` (v1) detection and
  env-file resolution mirror the pattern already used in
  :mod:`services` (``ServiceManager``).
* Passwords are **never** interpolated into a shell string. They are passed as
  discrete argv elements (``-p<password>``) to ``mysqldump``/``mysql`` and the
  pipeline is built with :class:`subprocess.Popen` chaining (no ``shell=True``).
* The module is CLI-runnable so a cron job can invoke it directly without
  Flask running::

      python3 server/backup_restore.py backup --description "scheduled"
      python3 server/backup_restore.py restore --id 20260718_120000
      python3 server/backup_restore.py list
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

# Default timeout (seconds) for any docker / gzip subprocess invocation.
DEFAULT_TIMEOUT = 600

# Timestamp directory / manifest id format: YYYYMMDD_HHMMSS (lexicographically
# sortable, so string comparison == chronological comparison).
TIMESTAMP_FMT = "%Y%m%d_%H%M%S"

# The user used to run mysqldump / mysql inside the container. The spec mandates
# ``root`` (with DB_ROOT_PASSWORD); the application DB_USER/DB_PASSWORD are read
# for completeness but the dump/restore always runs as root.
DUMP_USER = "root"

# Allowed characters for a database name passed on the command line.
_DB_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")


class BackupManager:
    """Create, list and restore MySQL dumps for the DevStack stack."""

    def __init__(
        self,
        root: str | Path | None = None,
        timeout: int = DEFAULT_TIMEOUT,
        *,
        db_root_password: str | None = None,
        db_name: str | None = None,
        db_user: str | None = None,
        db_password: str | None = None,
        db_host: str | None = None,
        db_port: int | str | None = None,
    ) -> None:
        # Project root is the parent of the ``server`` package directory.
        self.root = Path(root).resolve() if root else Path(__file__).resolve().parent.parent
        self.backups_dir = self.root / "backups"
        self.timeout = timeout

        # Compose command discovery (v2 -> v1) and env-file resolution, mirroring
        # the ServiceManager pattern in services.py.
        self.docker_cmd = self._detect_docker_command()
        self.compose_file = self.root / "docker" / "docker-compose.yml"
        self.env_file = self._resolve_env_file()

        # Best-effort env load so credentials are available when run standalone.
        self._load_env()

        # Credentials: explicit constructor args win, otherwise the environment.
        self.db_root_password = (
            db_root_password if db_root_password is not None else os.getenv("DB_ROOT_PASSWORD", "")
        )
        self.db_name = db_name if db_name is not None else os.getenv("DB_NAME", "")
        self.db_user = db_user if db_user is not None else os.getenv("DB_USER", "root")
        self.db_password = db_password if db_password is not None else os.getenv("DB_PASSWORD", "")
        self.db_host = db_host if db_host is not None else os.getenv("DB_HOST", "mysql")
        try:
            self.db_port = int(db_port if db_port is not None else os.getenv("DB_PORT", "3306"))
        except (TypeError, ValueError):
            self.db_port = 3306

    # ------------------------------------------------------------------
    # Setup / discovery helpers (mirrors ServiceManager)
    # ------------------------------------------------------------------
    def _resolve_env_file(self) -> Path:
        """Prefer ``<root>/.env``; fall back to ``<root>/.env.example``."""
        env = self.root / ".env"
        if env.is_file():
            return env
        example = self.root / ".env.example"
        if example.is_file():
            return example
        return env

    def _detect_docker_command(self) -> list[str]:
        """Return the docker compose invocation to use (v2 preferred, v1 fallback)."""
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

    @staticmethod
    def _load_env() -> None:
        """Load ``.env`` / ``.env.example`` if python-dotenv is available."""
        try:
            from dotenv import load_dotenv

            load_dotenv(Path(__file__).resolve().parent.parent / ".env")
            load_dotenv(Path(__file__).resolve().parent.parent / ".env.example")
        except Exception:
            # dotenv is optional for the pure logic; env may already be set.
            pass

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------
    @staticmethod
    def _validate_db_name(name: str | None) -> bool:
        """Return True for ``all``/empty (meaning all databases) or a safe name."""
        if name in ("all", "", None):
            return True
        return bool(_DB_NAME_RE.match(name))

    # ------------------------------------------------------------------
    # Command building (pure, easy to unit test)
    # ------------------------------------------------------------------
    def _compose_base(self) -> list[str]:
        """Build the common ``docker compose`` prefix shared by every invocation."""
        cmd = list(self.docker_cmd)
        cmd += ["--env-file", str(self.env_file)]
        cmd += ["-f", str(self.compose_file)]
        return cmd

    def _dump_argv(self, database: str) -> list[str]:
        """Build the ``mysqldump`` argv for ``database`` (or all databases).

        Password is passed as a discrete argv element (``-p<password>``) so it is
        never interpolated into a shell string.
        """
        cmd = self._compose_base()
        cmd += ["exec", "-T", self.db_host, "mysqldump", f"-u{DUMP_USER}", f"-p{self.db_root_password}"]
        if database in ("all", "", None):
            cmd += ["--all-databases"]
        else:
            cmd += ["--databases", database]
        return cmd

    def _mysql_argv(self, database: str | None) -> list[str]:
        """Build the ``mysql`` client argv for restore (optionally a target db)."""
        cmd = self._compose_base()
        cmd += ["exec", "-T", self.db_host, "mysql", f"-u{DUMP_USER}", f"-p{self.db_root_password}"]
        if database:
            cmd += [database]
        return cmd

    def _restore_stages(self, sql_file: Path, database: str | None) -> list[list[str]]:
        """Return the two-stage pipeline ``gunzip -c <file> | mysql ...``."""
        gunzip = ["gunzip", "-c", str(sql_file)]
        mysql = self._mysql_argv(database)
        return [gunzip, mysql]

    # ------------------------------------------------------------------
    # Pipeline execution
    # ------------------------------------------------------------------
    def _pipeline(self, stages: list[list[str]], out_file: Path | None = None) -> dict:
        """Run ``stages[0] | stages[1] | ... | stages[-1]`` without a shell.

        If ``out_file`` is given the final stage writes to it; otherwise its
        stdout is captured. Returns a structured result and never raises on the
        expected subprocess failures (missing binary, timeout, non-zero exit).
        """
        procs: list[subprocess.Popen] = []
        out_fh = None
        try:
            for i, stage in enumerate(stages):
                stdin = procs[-1].stdout if procs else None
                is_last = i == len(stages) - 1
                if is_last and out_file is not None:
                    out_fh = open(out_file, "wb")
                    stdout: object = out_fh
                else:
                    stdout = subprocess.PIPE
                proc = subprocess.Popen(stage, stdin=stdin, stdout=stdout, stderr=subprocess.PIPE)
                # Close the upstream's stdout in the parent so the downstream
                # reader receives EOF when the upstream process finishes.
                if procs:
                    procs[-1].stdout.close()
                procs.append(proc)

            last = procs[-1]
            out, err = last.communicate(timeout=self.timeout)
            for p in procs[:-1]:
                p.wait(timeout=self.timeout)

            failed = next((p for p in procs if p.returncode != 0), None)
            if failed is not None:
                detail = ""
                if failed.stderr:
                    try:
                        detail = failed.stderr.read().decode("utf-8", "replace").strip()
                    except Exception:
                        detail = ""
                return {
                    "success": False,
                    "message": detail or f"Command failed (exit {failed.returncode})",
                }
            return {
                "success": True,
                "message": "OK",
                "stdout": out.decode("utf-8", "replace") if isinstance(out, bytes) else (out or ""),
            }
        except FileNotFoundError as exc:
            return {
                "success": False,
                "message": f"Command not found: {exc}. Is Docker installed?",
            }
        except subprocess.TimeoutExpired:
            for p in procs:
                try:
                    if p.stdout:
                        p.stdout.close()
                    if p.stderr:
                        p.stderr.close()
                    p.kill()
                except Exception:
                    pass
            return {
                "success": False,
                "message": f"Command timed out after {self.timeout}s",
            }
        except OSError as exc:
            return {
                "success": False,
                "message": f"OS error running command: {exc}",
            }
        finally:
            if out_fh is not None:
                try:
                    out_fh.close()
                except Exception:
                    pass
            for p in procs:
                try:
                    if p.stderr:
                        p.stderr.close()
                except Exception:
                    pass

    # ------------------------------------------------------------------
    # Manifest helpers (pure-ish, easy to unit test)
    # ------------------------------------------------------------------
    @staticmethod
    def _read_manifest(path: Path) -> dict | None:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, json.JSONDecodeError):
            return None

    @staticmethod
    def _write_manifest(backup_dir: Path, manifest: dict) -> None:
        with open(backup_dir / "manifest.json", "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2)

    @staticmethod
    def _dir_size(directory: Path) -> int:
        total = 0
        for p in Path(directory).rglob("*"):
            if p.is_file():
                total += p.stat().st_size
        return total

    @staticmethod
    def _safe_rmtree(directory: Path) -> None:
        try:
            shutil.rmtree(directory, ignore_errors=True)
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def backup(self, database: str = "all", description: str = "") -> dict:
        """Create a gzipped MySQL dump.

        Returns ``{"success", "backup_id", "path", "files", "message"}``.
        """
        if not self._validate_db_name(database):
            return {
                "success": False,
                "message": (
                    f"Invalid database name: {database!r}. "
                    "Use 'all' or a name matching [A-Za-z0-9_]+."
                ),
                "backup_id": None,
                "path": None,
                "files": [],
            }

        database = "all" if database in ("", None) else database
        timestamp = datetime.now().strftime(TIMESTAMP_FMT)
        backup_dir = self.backups_dir / timestamp

        try:
            backup_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return {
                "success": False,
                "message": f"Could not create backup directory: {exc}",
                "backup_id": timestamp,
                "path": str(backup_dir),
                "files": [],
            }

        file_name = f"{database}.sql.gz"
        out_file = backup_dir / file_name

        dump_argv = self._dump_argv(database)
        gzip_argv = ["gzip", "-c"]
        result = self._pipeline([dump_argv, gzip_argv], out_file=out_file)

        if not result["success"]:
            # Do not leave a half-written / empty backup directory behind.
            self._safe_rmtree(backup_dir)
            return {
                "success": False,
                "message": result["message"],
                "backup_id": timestamp,
                "path": str(backup_dir),
                "files": [],
            }

        files = [file_name]
        manifest = {
            "id": timestamp,
            "timestamp": timestamp,
            "description": description or "",
            "database": database,
            "files": files,
            "size_bytes": self._dir_size(backup_dir),
        }
        self._write_manifest(backup_dir, manifest)

        return {
            "success": True,
            "backup_id": timestamp,
            "path": str(backup_dir),
            "files": files,
            "message": f"Backup '{timestamp}' created.",
        }

    def list_backups(self) -> list[dict]:
        """Scan ``<backups_dir>/*/manifest.json`` and return a sorted list.

        Sorted by timestamp descending (newest first). Returns ``[]`` when the
        backups directory is missing or empty.
        """
        if not self.backups_dir.is_dir():
            return []

        results: list[dict] = []
        for manifest_path in sorted(self.backups_dir.glob("*/manifest.json")):
            data = self._read_manifest(manifest_path)
            if data is None:
                continue
            results.append(
                {
                    "id": data.get("id"),
                    "timestamp": data.get("timestamp"),
                    "description": data.get("description", ""),
                    "database": data.get("database"),
                    "size_bytes": data.get("size_bytes", 0),
                    "files": data.get("files", []),
                }
            )

        results.sort(key=lambda x: x.get("timestamp") or "", reverse=True)
        return results

    def get_backup(self, backup_id: str) -> dict:
        """Return a single backup manifest, or a structured error if missing."""
        manifest_path = self.backups_dir / str(backup_id) / "manifest.json"
        if not manifest_path.is_file():
            return {
                "success": False,
                "message": f"Backup not found: {backup_id}",
                "missing": True,
            }
        data = self._read_manifest(manifest_path)
        if data is None:
            return {
                "success": False,
                "message": f"Backup manifest unreadable: {backup_id}",
                "missing": True,
            }
        return data

    def restore(self, backup_id: str, database: str | None = None) -> dict:
        """Restore a backup produced by :meth:`backup`.

        Returns ``{"success", "message"}``. Sets ``missing: True`` when the
        backup id does not exist so the caller can return a 404.
        """
        if database is not None and not self._validate_db_name(database):
            return {
                "success": False,
                "message": (
                    f"Invalid database name: {database!r}. "
                    "Use a name matching [A-Za-z0-9_]+."
                ),
            }

        info = self.get_backup(backup_id)
        if isinstance(info, dict) and info.get("missing"):
            return {
                "success": False,
                "message": info.get("message", "Backup not found"),
                "missing": True,
            }

        backup_dir = self.backups_dir / str(backup_id)
        files = info.get("files", [])
        if not files:
            return {
                "success": False,
                "message": "Backup manifest contains no files to restore.",
            }

        errors: list[str] = []
        for fname in files:
            sql_file = backup_dir / fname
            if not sql_file.is_file():
                errors.append(f"missing file: {fname}")
                continue
            stages = self._restore_stages(sql_file, database)
            res = self._pipeline(stages)
            if not res["success"]:
                errors.append(f"{fname}: {res['message']}")

        if errors:
            return {"success": False, "message": "; ".join(errors)}

        return {
            "success": True,
            "message": f"Restore from '{backup_id}' completed.",
        }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    """CLI entry point: backup / restore / list."""
    import argparse

    parser = argparse.ArgumentParser(description="DevStack database backup/restore CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    p_backup = sub.add_parser("backup", help="Create a database backup")
    p_backup.add_argument("--database", default="all", help="Database name or 'all' (default)")
    p_backup.add_argument("--description", default="", help="Free-text description for the manifest")

    p_restore = sub.add_parser("restore", help="Restore a database backup")
    p_restore.add_argument("--id", required=True, help="Backup id (timestamp directory name)")
    p_restore.add_argument("--database", default=None, help="Target database (optional)")

    sub.add_parser("list", help="List existing backups")

    args = parser.parse_args(argv)
    manager = BackupManager()

    if args.command == "backup":
        result = manager.backup(database=args.database, description=args.description)
        print(json.dumps(result, indent=2))
        return 0 if result["success"] else 1

    if args.command == "restore":
        result = manager.restore(backup_id=args.id, database=args.database)
        print(json.dumps(result, indent=2))
        return 0 if result["success"] else 1

    if args.command == "list":
        print(json.dumps(manager.list_backups(), indent=2))
        return 0

    parser.error("unknown command")
    return 2  # pragma: no cover


if __name__ == "__main__":
    raise SystemExit(main())
