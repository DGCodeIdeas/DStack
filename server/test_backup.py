"""Unit-style tests for BackupManager.

These tests do NOT require Docker or a running daemon; they exercise the pure
logic (manifest I/O, gzip round-trip, command argv building) and the
daemon-unavailable error path by monkeypatching ``subprocess``.

Run with::

    python3 server/test_backup.py
"""

from __future__ import annotations

import gzip
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

# Ensure the server package is importable when run as a script.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from backup_restore import BackupManager


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"FAILED: {message}")
    print(f"  ok: {message}")


def test_list_backups_empty_dir() -> None:
    """list_backups() returns [] when backups dir is missing or empty."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp)
        _assert(mgr.list_backups() == [], "empty dir -> empty list")

        # Create backups dir but leave it empty.
        (Path(tmp) / "backups").mkdir()
        _assert(mgr.list_backups() == [], "empty backups dir -> empty list")


def test_list_backups_with_fake_manifest() -> None:
    """list_backups() parses manifest.json and returns sorted list."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp)
        backups_dir = Path(tmp) / "backups"
        backups_dir.mkdir()

        # Create two fake backup dirs with manifests.
        for ts, desc, db in [
            ("20260718_100000", "first", "all"),
            ("20260718_120000", "second", "mydb"),
        ]:
            bdir = backups_dir / ts
            bdir.mkdir()
            manifest = {
                "id": ts,
                "timestamp": ts,
                "description": desc,
                "database": db,
                "files": [f"{db}.sql.gz"],
                "size_bytes": 123,
            }
            (bdir / "manifest.json").write_text(json.dumps(manifest))
            # Create a dummy .sql.gz so size_bytes > 0.
            (bdir / f"{db}.sql.gz").write_bytes(b"x")

        result = mgr.list_backups()
        _assert(len(result) == 2, "two backups found")
        # Sorted newest first (lexicographic on timestamp works for YYYYMMDD_HHMMSS).
        _assert(result[0]["id"] == "20260718_120000", "newest first")
        _assert(result[1]["id"] == "20260718_100000", "older second")
        _assert(result[0]["description"] == "second", "description preserved")
        _assert(result[0]["database"] == "mydb", "database preserved")
        _assert(result[0]["files"] == ["mydb.sql.gz"], "files list preserved")


def test_manifest_roundtrip() -> None:
    """_write_manifest + _read_manifest preserves data."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp)
        bdir = Path(tmp) / "backups" / "20260718_120000"
        bdir.mkdir(parents=True)

        manifest = {
            "id": "20260718_120000",
            "timestamp": "20260718_120000",
            "description": "test",
            "database": "mydb",
            "files": ["mydb.sql.gz"],
            "size_bytes": 456,
        }
        mgr._write_manifest(bdir, manifest)
        read_back = mgr._read_manifest(bdir / "manifest.json")
        _assert(read_back == manifest, "manifest round-trip identical")


def test_gzip_roundtrip() -> None:
    """gzip.compress -> gzip.decompress yields original bytes."""
    original = b"CREATE TABLE t (id INT);\nINSERT INTO t VALUES (1);\n"
    compressed = gzip.compress(original)
    decompressed = gzip.decompress(compressed)
    _assert(decompressed == original, "gzip round-trip preserves data")


def test_dump_argv_all_databases() -> None:
    """_dump_argv('all') produces the expected argv list."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret")
        argv = mgr._dump_argv("all")
        # Should contain: docker compose --env-file ... -f ... exec -T mysql mysqldump -uroot -psecret --all-databases
        _assert(argv[0:2] == ["docker", "compose"], "docker compose prefix")
        _assert("--all-databases" in argv, "all-databases flag present")
        _assert("-psecret" in argv, "password passed as discrete arg")
        _assert("--databases" not in argv, "no --databases when all")


def test_dump_argv_specific_database() -> None:
    """_dump_argv('mydb') produces --databases mydb."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret")
        argv = mgr._dump_argv("mydb")
        _assert("--databases" in argv, "databases flag present")
        _assert(argv[argv.index("--databases") + 1] == "mydb", "db name follows flag")
        _assert("--all-databases" not in argv, "no all-databases flag")


def test_mysql_argv_with_database() -> None:
    """_mysql_argv('mydb') includes the database name."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret")
        argv = mgr._mysql_argv("mydb")
        _assert(argv[-1] == "mydb", "database name is last arg")


def test_mysql_argv_without_database() -> None:
    """_mysql_argv(None) does not append a database name."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret")
        argv = mgr._mysql_argv(None)
        _assert(argv[-1] != "mysql", "last arg is not a db name")
        _assert(argv[-1] == "-psecret", "last arg is password")


def test_restore_stages() -> None:
    """_restore_stages returns [gunzip, mysql] argv lists."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret")
        sql_file = Path(tmp) / "backup.sql.gz"
        stages = mgr._restore_stages(sql_file, "mydb")
        _assert(len(stages) == 2, "two stages: gunzip | mysql")
        _assert(stages[0][0] == "gunzip", "first stage is gunzip")
        _assert(stages[0][1] == "-c", "gunzip -c")
        _assert(stages[0][2] == str(sql_file), "gunzip input file")
        _assert(stages[1][0:2] == ["docker", "compose"], "second stage docker compose")
        _assert("mysql" in stages[1], "mysql client in second stage")


def test_validate_db_name() -> None:
    """_validate_db_name accepts 'all', '', None, and alnum/underscore names."""
    _assert(BackupManager._validate_db_name("all"), "all")
    _assert(BackupManager._validate_db_name(""), "empty string")
    _assert(BackupManager._validate_db_name(None), "None")
    _assert(BackupManager._validate_db_name("mydb"), "alnum")
    _assert(BackupManager._validate_db_name("my_db123"), "underscore and digits")
    _assert(not BackupManager._validate_db_name("my-db"), "hyphen rejected")
    _assert(not BackupManager._validate_db_name("my db"), "space rejected")
    _assert(not BackupManager._validate_db_name("my;db"), "semicolon rejected")


def test_backup_daemon_unavailable_returns_structured_error() -> None:
    """backup() returns structured error when docker compose not found."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret", timeout=1)

        # Monkeypatch subprocess.Popen to simulate FileNotFoundError (docker not installed).
        def fake_popen(*args, **kwargs):
            raise FileNotFoundError("docker")

        with patch("subprocess.Popen", fake_popen):
            result = mgr.backup(database="all", description="test")
        _assert(result["success"] is False, "success is False")
        _assert("not found" in result["message"].lower() or "docker" in result["message"].lower(), "error mentions docker")
        _assert(result["backup_id"] is not None, "backup_id present")
        _assert(result["files"] == [], "no files on failure")


def test_backup_subprocess_timeout_returns_structured_error() -> None:
    """backup() returns structured error on subprocess.TimeoutExpired."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret", timeout=1)

        # Create a mock Popen that times out on communicate.
        class MockProc:
            def __init__(self):
                self.returncode = 0
                self.stderr = None
                self.stdout = io.BytesIO(b"")
            def communicate(self, timeout=None):
                raise subprocess.TimeoutExpired(cmd=["docker"], timeout=1)
            def wait(self, timeout=None):
                pass
            def kill(self):
                pass

        def fake_popen(*args, **kwargs):
            return MockProc()

        with patch("subprocess.Popen", fake_popen):
            result = mgr.backup(database="all", description="test")
        _assert(result["success"] is False, "success is False")
        _assert("timed out" in result["message"].lower(), "error mentions timeout")


def test_backup_subprocess_nonzero_returns_structured_error() -> None:
    """backup() returns structured error when mysqldump exits non-zero."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret", timeout=1)

        # Create a mock Popen that returns non-zero exit code.
        class MockProc:
            def __init__(self):
                self.returncode = 1
                self.stderr = io.BytesIO(b"mysqldump: Access denied")
                self.stdout = io.BytesIO(b"")
            def communicate(self, timeout=None):
                return (b"", b"mysqldump: Access denied")
            def wait(self, timeout=None):
                pass
            def kill(self):
                pass

        def fake_popen(*args, **kwargs):
            return MockProc()

        with patch("subprocess.Popen", fake_popen):
            result = mgr.backup(database="all", description="test")
        _assert(result["success"] is False, "success is False")
        _assert("access denied" in result["message"].lower(), "error message propagated")


def test_restore_missing_backup_returns_missing_flag() -> None:
    """restore() returns missing=True when backup_id not found."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp)
        result = mgr.restore(backup_id="nonexistent")
        _assert(result["success"] is False, "success is False")
        _assert(result.get("missing") is True, "missing flag set")


def test_restore_daemon_unavailable_returns_structured_error() -> None:
    """restore() returns structured error when docker compose not found."""
    with tempfile.TemporaryDirectory() as tmp:
        mgr = BackupManager(root=tmp, db_root_password="secret", timeout=1)
        # Create a fake backup dir with manifest.
        bdir = Path(tmp) / "backups" / "20260718_120000"
        bdir.mkdir(parents=True)
        manifest = {
            "id": "20260718_120000",
            "timestamp": "20260718_120000",
            "description": "test",
            "database": "all",
            "files": ["all.sql.gz"],
            "size_bytes": 100,
        }
        (bdir / "manifest.json").write_text(json.dumps(manifest))
        (bdir / "all.sql.gz").write_bytes(gzip.compress(b"dummy"))

        # Create a mock Popen that raises FileNotFoundError.
        class MockProc:
            def __init__(self):
                self.returncode = 0
                self.stdout = io.BytesIO()
                self.stderr = io.BytesIO()
            def communicate(self, timeout=None):
                raise FileNotFoundError("docker")
            def wait(self, timeout=None):
                pass
            def kill(self):
                pass

        def fake_popen(*args, **kwargs):
            raise FileNotFoundError("docker")

        with patch("subprocess.Popen", fake_popen):
            result = mgr.restore(backup_id="20260718_120000")
        _assert(result["success"] is False, "success is False")
        _assert("not found" in result["message"].lower() or "docker" in result["message"].lower(), "error mentions docker")


def test_cli_backup_command() -> None:
    """CLI 'backup' subcommand runs and prints JSON (monkeypatched)."""
    from backup_restore import main

    with tempfile.TemporaryDirectory() as tmp:
        # Monkeypatch BackupManager.backup to avoid subprocess.
        def fake_backup(self, database="all", description=""):
            return {
                "success": True,
                "backup_id": "20260718_120000",
                "path": f"{tmp}/backups/20260718_120000",
                "files": ["all.sql.gz"],
                "message": "ok",
            }

        with patch.object(BackupManager, "backup", fake_backup):
            # Capture stdout.
            import io
            old_stdout = sys.stdout
            sys.stdout = io.StringIO()
            try:
                rc = main(["backup", "--database", "mydb", "--description", "test"])
                output = sys.stdout.getvalue()
            finally:
                sys.stdout = old_stdout

        _assert(rc == 0, "exit code 0 on success")
        data = json.loads(output)
        _assert(data["success"] is True, "CLI prints success JSON")
        _assert(data["backup_id"] == "20260718_120000", "backup_id in output")


def test_cli_restore_command() -> None:
    """CLI 'restore' subcommand runs and prints JSON (monkeypatched)."""
    from backup_restore import main

    def fake_restore(self, backup_id, database=None):
        return {"success": True, "message": "restored"}

    with patch.object(BackupManager, "restore", fake_restore):
        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            rc = main(["restore", "--id", "20260718_120000"])
            output = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout

    _assert(rc == 0, "exit code 0 on success")
    data = json.loads(output)
    _assert(data["success"] is True, "CLI prints success JSON")


def test_cli_list_command() -> None:
    """CLI 'list' subcommand prints JSON array."""
    from backup_restore import main

    def fake_list(self):
        return [{"id": "20260718_120000", "database": "all"}]

    with patch.object(BackupManager, "list_backups", fake_list):
        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        try:
            rc = main(["list"])
            output = sys.stdout.getvalue()
        finally:
            sys.stdout = old_stdout

    _assert(rc == 0, "exit code 0")
    data = json.loads(output)
    _assert(isinstance(data, list), "output is a list")
    _assert(data[0]["id"] == "20260718_120000", "backup id present")


def main() -> None:
    print("Running BackupManager unit tests...")
    test_list_backups_empty_dir()
    test_list_backups_with_fake_manifest()
    test_manifest_roundtrip()
    test_gzip_roundtrip()
    test_dump_argv_all_databases()
    test_dump_argv_specific_database()
    test_mysql_argv_with_database()
    test_mysql_argv_without_database()
    test_restore_stages()
    test_validate_db_name()
    test_backup_daemon_unavailable_returns_structured_error()
    test_backup_subprocess_timeout_returns_structured_error()
    test_backup_subprocess_nonzero_returns_structured_error()
    test_restore_missing_backup_returns_missing_flag()
    test_restore_daemon_unavailable_returns_structured_error()
    test_cli_backup_command()
    test_cli_restore_command()
    test_cli_list_command()
    print("\nAll tests passed.")


if __name__ == "__main__":
    main()