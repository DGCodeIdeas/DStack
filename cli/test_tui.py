#!/usr/bin/env python3
"""Unit tests for cli/tui.py.

Tests cover:
- Menu dispatch invokes expected callbacks
- Selector handles key sequences (numbered input, 'q' to quit)
- Non-TTY fallback works with piped input
- Helper functions (is_tty, confirm_action, pause)
- Smoke test: import and basic execution
"""

from __future__ import annotations

import sys
import io
from pathlib import Path
from unittest.mock import patch, MagicMock, call

import pytest

# Ensure server package is importable
SERVER_DIR = Path(__file__).resolve().parent.parent / "server"
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

ROOT_DIR = Path(__file__).resolve().parent.parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from cli.tui import (
    Menu,
    ServicesMenu,
    VhostsMenu,
    SSLMenu,
    RDSMenu,
    BackupsMenu,
    LogsMenu,
    MainMenu,
    is_tty,
    confirm_action,
    pause,
    main,
)


# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------
SAMPLE_STATUS = {
    "nginx": {"status": "Up 5 minutes", "state": "running", "health": "healthy"},
    "php": {"status": "Up 5 minutes", "state": "running", "health": None},
    "mysql": {"status": "Up 5 minutes", "state": "running", "health": "healthy"},
    "redis": {"status": "Up 5 minutes", "state": "running", "health": None},
    "phpmyadmin": {"status": "Up 5 minutes", "state": "running", "health": None},
}


def make_mock_console():
    """Create a mock console that captures output."""
    mock = MagicMock()
    mock.print = MagicMock()
    mock.clear = MagicMock()
    return mock


# ---------------------------------------------------------------------------
# is_tty tests
# ---------------------------------------------------------------------------
def test_is_tty_false_when_patched(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    assert is_tty() is False

    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    assert is_tty() is True


# ---------------------------------------------------------------------------
# confirm_action tests
# ---------------------------------------------------------------------------
def test_confirm_action_uses_default_in_non_tty(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    assert confirm_action("Test?", default=True) is True
    assert confirm_action("Test?", default=False) is False


def test_confirm_action_uses_prompt_in_tty(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    with patch("cli.tui.Confirm.ask", return_value=True) as mock_ask:
        result = confirm_action("Test?", default=False)
        assert result is True
        mock_ask.assert_called_once()


# ---------------------------------------------------------------------------
# pause tests
# ---------------------------------------------------------------------------
def test_pause_does_not_block_in_non_tty(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    # Should not raise or block
    pause()


def test_pause_uses_prompt_in_tty(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    with patch("cli.tui.Prompt.ask", return_value="") as mock_ask:
        pause()
        mock_ask.assert_called_once()


# ---------------------------------------------------------------------------
# Menu tests - patching is_tty directly
# ---------------------------------------------------------------------------
def test_menu_dispatch_invokes_callback():
    """Selecting a menu option should invoke its callback."""
    called = {"count": 0}

    def callback():
        called["count"] += 1
        return None

    menu = Menu("Test Menu", [
        ("Option 1", callback),
        ("Option 2", lambda: True),  # exit
    ])

    with patch("cli.tui.is_tty", return_value=False):
        with patch("sys.stdin", io.StringIO("0\n")):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                mock_console.clear = MagicMock()
                result = menu.run()

    assert called["count"] == 1
    assert result is None  # callback returned None -> continue


def test_menu_exit_on_quit():
    """Selecting 'q' or 'Q' or 'quit' or 'exit' should exit the menu."""
    menu = Menu("Test Menu", [
        ("Option 1", lambda: None),
    ])

    for quit_key in ["q", "Q", "quit", "exit"]:
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO(quit_key + "\n")):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    result = menu.run()
        assert result is True, f"Key {quit_key!r} should exit"

    # "0" is a valid menu index, not a quit key in _run_non_tty
    # Test that "0" selects the first option
    with patch("cli.tui.is_tty", return_value=False):
        with patch("sys.stdin", io.StringIO("0\n")):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                mock_console.clear = MagicMock()
                result = menu.run()
    # The callback returns None, so menu continues (returns None)
    assert result is None


def test_menu_callback_returning_true_exits():
    """Callback returning True should propagate exit signal."""
    menu = Menu("Test Menu", [
        ("Exit", lambda: True),
        ("Stay", lambda: None),
    ])

    with patch("cli.tui.is_tty", return_value=False):
        with patch("sys.stdin", io.StringIO("0\n")):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                mock_console.clear = MagicMock()
                result = menu.run()

    assert result is True


def test_menu_invalid_input_exits_in_non_tty():
    """Invalid input in non-TTY mode should exit cleanly."""
    menu = Menu("Test Menu", [
        ("Option 1", lambda: None),
    ])

    with patch("cli.tui.is_tty", return_value=False):
        with patch("sys.stdin", io.StringIO("invalid\n")):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                mock_console.clear = MagicMock()
                result = menu.run()

    assert result is True


def test_menu_non_tty_runs_callback_and_returns_its_result():
    """In non-TTY mode, menu should run callback and return its result."""
    menu = Menu("Test Menu", [
        ("Option 1", lambda: "callback_result"),
        ("Option 2", lambda: True),
    ])

    with patch("cli.tui.is_tty", return_value=False):
        with patch("sys.stdin", io.StringIO("0\n")):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                mock_console.clear = MagicMock()
                result = menu.run()

    assert result == "callback_result"


# ---------------------------------------------------------------------------
# ServicesMenu tests
# ---------------------------------------------------------------------------
def test_services_menu_list_services_calls_manager(monkeypatch):
    """ServicesMenu.list_services should call manager.get_all_status."""
    with patch("cli.tui.ServiceManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.get_all_status.return_value = SAMPLE_STATUS
        mock_manager_class.return_value = mock_manager

        # Input: 1 (List Services) -> 0 (Back)
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("1\n0\n")):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    ServicesMenu().run()

        mock_manager.get_all_status.assert_called_once()


def test_services_menu_start_service_calls_manager(monkeypatch):
    """ServicesMenu.start_service should call manager.start."""
    with patch("cli.tui.ServiceManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.start.return_value = {"success": True, "message": "Started"}
        mock_manager_class.return_value = mock_manager

        # Inputs: 2 (Start) -> nginx -> 0 (Back)
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("2\nnginx\n0\n")):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    ServicesMenu().run()

        mock_manager.start.assert_called_once_with("nginx")


def test_services_menu_stop_service_calls_manager(monkeypatch):
    """ServicesMenu.stop_service should call manager.stop."""
    with patch("cli.tui.ServiceManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.stop.return_value = {"success": True, "message": "Stopped"}
        mock_manager_class.return_value = mock_manager

        # Inputs: 3 (Stop) -> php -> 0 (Back)
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("3\nphp\n0\n")):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    ServicesMenu().run()

        mock_manager.stop.assert_called_once_with("php")


def test_services_menu_restart_service_calls_manager(monkeypatch):
    """ServicesMenu.restart_service should call manager.restart."""
    with patch("cli.tui.ServiceManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.restart.return_value = {"success": True, "message": "Restarted"}
        mock_manager_class.return_value = mock_manager

        # Inputs: 4 (Restart) -> mysql -> 0 (Back)
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("4\nmysql\n0\n")):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    ServicesMenu().run()

        mock_manager.restart.assert_called_once_with("mysql")


# ---------------------------------------------------------------------------
# VhostsMenu tests
# ---------------------------------------------------------------------------
def test_vhosts_menu_create_vhost_calls_manager(monkeypatch):
    """VhostsMenu.create_vhost should call manager.create with correct args."""
    with patch("cli.tui.VirtualHostManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.create.return_value = {"success": True, "warnings": []}
        mock_manager_class.return_value = mock_manager

        # Inputs: 2 (Create) -> test.local -> php -> (empty root) -> 0 (Back)
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("2\ntest.local\nphp\n\n0\n")):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    VhostsMenu().run()

        mock_manager.create.assert_called_once()
        args, kwargs = mock_manager.create.call_args
        assert args[0] == "test.local"
        assert kwargs.get("framework") == "php"
        assert kwargs.get("root") is None


def test_vhosts_menu_delete_vhost_calls_manager(monkeypatch):
    """VhostsMenu.delete_vhost should call manager.delete."""
    with patch("cli.tui.VirtualHostManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.list_all.return_value = [
            {"domain": "test.local", "root": "/path", "framework": "php", "config_path": "/path"}
        ]
        mock_manager.delete.return_value = {"success": True, "warnings": []}
        mock_manager_class.return_value = mock_manager

        # In non-TTY mode, confirm_action returns default (False for both).
        # We need to mock confirm_action to return True for first call (confirm delete),
        # False for second call (don't remove files).
        with patch("cli.tui.is_tty", return_value=False):
            with patch("cli.tui.confirm_action", side_effect=[True, False]):
                with patch("sys.stdin", io.StringIO("3\ntest.local\n0\n")):
                    with patch("cli.tui.console") as mock_console:
                        mock_console.print = MagicMock()
                        mock_console.clear = MagicMock()
                        VhostsMenu().run()

        mock_manager.delete.assert_called_once_with("test.local", remove_files=False)


# ---------------------------------------------------------------------------
# SSLMenu tests
# ---------------------------------------------------------------------------
def test_ssl_menu_create_mkcert_calls_manager(monkeypatch):
    """SSLMenu.create_mkcert should call manager.create_mkcert."""
    with patch("cli.tui.SSLManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.create_mkcert.return_value = {"success": True, "message": "OK", "warnings": []}
        mock_manager_class.return_value = mock_manager

        # Inputs: 3 (mkcert) -> test.local -> 0 (Back)
        with patch("sys.stdin", io.StringIO("3\ntest.local\n0\n")):
            with patch("sys.stdin.isatty", return_value=False):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    SSLMenu().run()

        mock_manager.create_mkcert.assert_called_once_with("test.local")


def test_ssl_menu_create_letsencrypt_calls_manager(monkeypatch):
    """SSLMenu.create_letsencrypt should call manager.create_letsencrypt."""
    with patch("cli.tui.SSLManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.create_letsencrypt.return_value = {"success": True, "message": "OK", "warnings": []}
        mock_manager_class.return_value = mock_manager

        # Inputs: 4 (letsencrypt) -> test.local -> admin@test.local -> standalone -> (empty webroot) -> 0 (Back)
        with patch("sys.stdin", io.StringIO("4\ntest.local\nadmin@test.local\nstandalone\n\n0\n")):
            with patch("sys.stdin.isatty", return_value=False):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    SSLMenu().run()

        mock_manager.create_letsencrypt.assert_called_once()
        args, kwargs = mock_manager.create_letsencrypt.call_args
        assert args[0] == "test.local"
        assert args[1] == "admin@test.local"
        assert kwargs.get("mode") == "standalone"


def test_ssl_menu_enable_ssl_calls_manager(monkeypatch):
    """SSLMenu.enable_ssl should call manager.enable_vhost_ssl."""
    with patch("cli.tui.SSLManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.enable_vhost_ssl.return_value = {"success": True, "message": "OK", "warnings": []}
        mock_manager_class.return_value = mock_manager

        # Inputs: 5 (Enable SSL) -> test.local -> y (redirect) -> 0 (Back)
        with patch("sys.stdin", io.StringIO("5\ntest.local\ny\n0\n")):
            with patch("sys.stdin.isatty", return_value=False):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    SSLMenu().run()

        mock_manager.enable_vhost_ssl.assert_called_once_with("test.local", redirect_http=True)


# ---------------------------------------------------------------------------
# RDSMenu tests
# ---------------------------------------------------------------------------
def test_rds_menu_connect_calls_tunnel(monkeypatch):
    """RDSMenu.connect should call tunnel.connect with validated params."""
    # Create a mock tunnel instance
    mock_tunnel = MagicMock()
    mock_tunnel.connect.return_value = {"success": True, "message": "Connected"}

    # Patch RDSTunnel to return our mock instance BEFORE creating RDSMenu
    # Also mock validate_connect_params to return None (no error) since the key file doesn't exist
    with patch("cli.tui.RDSTunnel", return_value=mock_tunnel):
        with patch("cli.tui.validate_connect_params", return_value=None):
            # Test the connect method directly, bypassing the menu
            rds_menu = RDSMenu()
            with patch("cli.tui.is_tty", return_value=False):
                with patch("cli.tui.Prompt.ask", side_effect=["ec2-host", "ec2-user", "/path/key", "rds-host"]):
                    with patch("cli.tui.IntPrompt.ask", side_effect=[3306, 3307]):
                        with patch("cli.tui.console") as mock_console:
                            mock_console.print = MagicMock()
                            mock_console.clear = MagicMock()
                            rds_menu.connect()

        mock_tunnel.connect.assert_called_once()
        args, kwargs = mock_tunnel.connect.call_args
        assert kwargs["ec2_host"] == "ec2-host"
        assert kwargs["ec2_user"] == "ec2-user"
        assert kwargs["ec2_key_path"] == "/path/key"
        assert kwargs["rds_host"] == "rds-host"
        assert kwargs["rds_port"] == 3306
        assert kwargs["local_port"] == 3307


def test_rds_menu_disconnect_calls_tunnel(monkeypatch):
    """RDSMenu.disconnect should call tunnel.disconnect."""
    with patch("cli.tui.RDSTunnel") as mock_tunnel_class:
        mock_tunnel = MagicMock()
        mock_tunnel.is_connected.return_value = True
        mock_tunnel.disconnect.return_value = {"success": True, "message": "Disconnected"}
        mock_tunnel_class.return_value = mock_tunnel

        # In non-TTY mode, confirm_action returns default (False)
        # We need to mock it to return True for the disconnect confirmation
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("3\n")):  # Select "Disconnect" option
                with patch("cli.tui.confirm_action", return_value=True):
                    with patch("cli.tui.console") as mock_console:
                        mock_console.print = MagicMock()
                        mock_console.clear = MagicMock()
                        RDSMenu().run()

        mock_tunnel.disconnect.assert_called_once()


# ---------------------------------------------------------------------------
# BackupsMenu tests
# ---------------------------------------------------------------------------
def test_backups_menu_create_backup_calls_manager(monkeypatch):
    """BackupsMenu.create_backup should call manager.backup."""
    with patch("cli.tui.BackupManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.backup.return_value = {"success": True, "backup_id": "20240101_120000"}
        mock_manager_class.return_value = mock_manager

        # Inputs: 2 (Create) -> all -> scheduled backup -> 0 (Back)
        with patch("sys.stdin", io.StringIO("2\nall\nscheduled backup\n0\n")):
            with patch("sys.stdin.isatty", return_value=False):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    BackupsMenu().run()

        mock_manager.backup.assert_called_once_with(database="all", description="scheduled backup")


def test_backups_menu_restore_backup_calls_manager(monkeypatch):
    """BackupsMenu.restore_backup should call manager.restore."""
    with patch("cli.tui.BackupManager") as mock_manager_class:
        mock_manager = MagicMock()
        mock_manager.list_backups.return_value = [
            {"id": "20240101_120000", "timestamp": "2024-01-01", "database": "all", "size_bytes": 1024, "description": "test"}
        ]
        mock_manager.restore.return_value = {"success": True, "message": "Restored"}
        mock_manager_class.return_value = mock_manager

        # In non-TTY mode, confirm_action returns default (False), so we need to mock it to return True
        # Also need to patch sys.stdin for the menu's _run_non_tty
        with patch("cli.tui.is_tty", return_value=False):
            with patch("sys.stdin", io.StringIO("3\n")):  # Select "Restore Backup" option
                with patch("cli.tui.confirm_action", return_value=True):
                    with patch("cli.tui.Prompt.ask", side_effect=["20240101_120000", ""]):
                        with patch("cli.tui.console") as mock_console:
                            mock_console.print = MagicMock()
                            mock_console.clear = MagicMock()
                            BackupsMenu().run()

        mock_manager.restore.assert_called_once_with("20240101_120000", database=None)


# ---------------------------------------------------------------------------
# LogsMenu tests
# ---------------------------------------------------------------------------
def test_logs_menu_view_logs_calls_aggregator(monkeypatch):
    """LogsMenu.view_logs should call aggregator.get_logs."""
    with patch("cli.tui.LogAggregator") as mock_agg_class:
        mock_agg = MagicMock()
        mock_agg.get_logs.return_value = {
            "success": True,
            "entries": [{"service": "nginx", "message": "GET /"}],
            "truncated": False,
        }
        mock_agg_class.return_value = mock_agg

        # Inputs: 1 (View) -> nginx -> 50 -> 0 (Back)
        with patch("sys.stdin", io.StringIO("1\nnginx\n50\n0\n")):
            with patch("sys.stdin.isatty", return_value=False):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    LogsMenu().run()

        mock_agg.get_logs.assert_called_once_with("nginx", lines=50)


def test_logs_menu_follow_logs_calls_aggregator(monkeypatch):
    """LogsMenu.follow_logs should call aggregator.stream_logs."""
    with patch("cli.tui.LogAggregator") as mock_agg_class:
        mock_agg = MagicMock()
        mock_agg.stream_logs.return_value = iter(["line1", "line2"])
        mock_agg_class.return_value = mock_agg

        # Inputs: 2 (Follow) -> nginx -> 0 (Back)
        with patch("sys.stdin", io.StringIO("2\nnginx\n0\n")):
            with patch("sys.stdin.isatty", return_value=False):
                with patch("cli.tui.console") as mock_console:
                    mock_console.print = MagicMock()
                    mock_console.clear = MagicMock()
                    LogsMenu().run()

        mock_agg.stream_logs.assert_called_once_with("nginx")


# ---------------------------------------------------------------------------
# MainMenu / main tests
# ---------------------------------------------------------------------------
def test_main_exits_cleanly_on_keyboard_interrupt(monkeypatch):
    """Main should handle KeyboardInterrupt gracefully."""
    with patch("cli.tui.MainMenu.run", side_effect=KeyboardInterrupt()):
        with patch("sys.stdin.isatty", return_value=False):
            result = main()
    assert result == 130


def test_main_exits_cleanly_on_exception(monkeypatch):
    """Main should handle generic exceptions gracefully."""
    with patch("cli.tui.MainMenu.run", side_effect=RuntimeError("test error")):
        with patch("sys.stdin.isatty", return_value=False):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                result = main()
    assert result == 1


def test_tui_imports_without_error():
    """Importing tui should not raise."""
    import cli.tui
    assert cli.tui is not None


# ---------------------------------------------------------------------------
# Smoke test: non-TTY execution
# ---------------------------------------------------------------------------
def test_smoke_run_non_tty_exits_cleanly(monkeypatch):
    """Running with piped input '0' should exit cleanly."""
    # This simulates: echo "0" | python3 cli/tui.py
    with patch("sys.stdin", io.StringIO("0\n")):
        with patch("sys.stdin.isatty", return_value=False):
            with patch("cli.tui.console") as mock_console:
                mock_console.print = MagicMock()
                mock_console.clear = MagicMock()
                result = main()

    assert result == 0


# ---------------------------------------------------------------------------
# Run tests when executed directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    pytest.main([__file__, "-v"])