#!/usr/bin/env python3
"""Rich-based TUI for DevStack management.

Provides an interactive terminal UI with arrow-key navigation and a
non-TTY fallback for piped/redirected input. Reuses the existing
server managers (ServiceManager, VirtualHostManager, SSLManager,
RDSTunnel, BackupManager, LogAggregator) so no Docker logic is
duplicated.

Usage:
    python3 cli/tui.py              # interactive (requires TTY)
    echo "0" | python3 cli/tui.py   # non-TTY smoke test (exits cleanly)
"""

from __future__ import annotations

import sys
import os
from pathlib import Path
from typing import Callable, Optional

# Ensure the server package is importable when running from cli/
SERVER_DIR = Path(__file__).resolve().parent.parent / "server"
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

# Also add project root for any other imports
ROOT_DIR = Path(__file__).resolve().parent.parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.prompt import Prompt, IntPrompt, Confirm
from rich.text import Text
from rich.align import Align
from rich.live import Live
from rich.layout import Layout
from rich import box

# Server managers
from services import ServiceManager, KNOWN_SERVICES
from virtual_hosts import VirtualHostManager, validate_domain, SUPPORTED_FRAMEWORKS
from ssl_manager import SSLManager
from rds_tunnel import RDSTunnel, validate_connect_params, DEFAULT_LOCAL_PORT, DEFAULT_RDS_PORT
from backup_restore import BackupManager
from logs_aggregator import LogAggregator, DEFAULT_LINES, VALID_TARGETS


# ---------------------------------------------------------------------------
# Console & helpers
# ---------------------------------------------------------------------------
console = Console()

def is_tty() -> bool:
    """Return True if stdin is a TTY (interactive)."""
    return sys.stdin.isatty()


def clear_screen() -> None:
    console.clear()


def print_header(title: str) -> None:
    console.print(Panel(Align.center(Text(title, style="bold cyan")), box=box.ROUNDED, style="cyan"))


def print_info(msg: str) -> None:
    console.print(f"[cyan]ℹ[/cyan] {msg}")


def print_success(msg: str) -> None:
    console.print(f"[green]✓[/green] {msg}")


def print_error(msg: str) -> None:
    console.print(f"[red]✗[/red] {msg}")


def print_warning(msg: str) -> None:
    console.print(f"[yellow]⚠[/yellow] {msg}")


def pause() -> None:
    """Pause for user input (works in both TTY and non-TTY)."""
    if is_tty():
        Prompt.ask("\n[dim]Press Enter to continue...[/dim]", default="", show_default=False)
    else:
        # In non-TTY mode, just continue
        pass


def confirm_action(msg: str, default: bool = False) -> bool:
    """Confirm an action (works in both TTY and non-TTY)."""
    if is_tty():
        return Confirm.ask(msg, default=default)
    # Non-TTY: use default
    return default


# ---------------------------------------------------------------------------
# Menu system
# ---------------------------------------------------------------------------
class Menu:
    """Simple arrow-key menu with non-TTY fallback."""

    def __init__(self, title: str, options: list[tuple[str, Callable[[], Optional[bool]]]]):
        """
        Args:
            title: Menu title
            options: List of (label, callback) tuples. Callback returns True to exit menu, False/None to continue.
        """
        self.title = title
        self.options = options
        self.selected = 0

    def render(self) -> Table:
        table = Table(box=box.SIMPLE, show_header=False, pad_edge=False)
        table.add_column(" ", style="cyan", width=3)
        table.add_column("Option", style="white")
        for i, (label, _) in enumerate(self.options):
            prefix = "▶" if i == self.selected else " "
            style = "bold cyan" if i == self.selected else "white"
            table.add_row(prefix, Text(label, style=style))
        return table

    def run(self) -> Optional[bool]:
        """Run the menu loop. Returns True if user chose to exit the app."""
        if not is_tty():
            return self._run_non_tty()

        with Live(self.render(), console=console, refresh_per_second=30, transient=True) as live:
            while True:
                live.update(self.render())
                key = console.input("")  # This blocks; we'll handle keys differently

                # Actually, let's use a simpler approach for arrow keys
                # Rich's Prompt doesn't do arrow keys well, so let's use a different approach
                break

        # Fallback to simple numbered menu for now
        return self._run_simple()

    def _run_simple(self) -> Optional[bool]:
        """Simple numbered menu (works in both TTY and non-TTY)."""
        while True:
            clear_screen()
            print_header(self.title)
            console.print(self.render())
            console.print()

            if is_tty():
                choice = Prompt.ask(
                    "Select option",
                    choices=[str(i) for i in range(len(self.options))] + ["q"],
                    show_choices=False,
                )
            else:
                # Non-TTY: read a line
                line = sys.stdin.readline()
                if not line:
                    return True  # EOF -> exit
                choice = line.strip()

            if choice in ("q", "Q", "quit", "exit"):
                return True

            try:
                idx = int(choice)
                if 0 <= idx < len(self.options):
                    label, callback = self.options[idx]
                    console.print(f"\n[cyan]→ {label}[/cyan]\n")
                    result = callback()
                    if result is True:
                        return True
                    pause()
                    continue
            except ValueError:
                pass

            if not is_tty():
                # In non-TTY, invalid input exits
                return True

            print_error("Invalid selection. Try again.")
            pause()

    def _run_non_tty(self) -> Optional[bool]:
        """Non-TTY fallback: print menu once, read one line, execute or exit."""
        clear_screen()
        print_header(self.title)
        console.print(self.render())
        console.print()

        line = sys.stdin.readline()
        if not line:
            return True
        choice = line.strip()

        if choice in ("q", "Q", "quit", "exit"):
            return True

        try:
            idx = int(choice)
            if 0 <= idx < len(self.options):
                _, callback = self.options[idx]
                return callback()
        except ValueError:
            pass

        return True  # Invalid input -> exit cleanly


# ---------------------------------------------------------------------------
# Service Manager TUI
# ---------------------------------------------------------------------------
class ServicesMenu:
    def __init__(self):
        self.manager = ServiceManager()

    def _build_table(self, status: dict) -> Table:
        table = Table(title="DevStack Services", box=box.ROUNDED)
        table.add_column("Service", style="cyan", no_wrap=True)
        table.add_column("Status", style="green")
        table.add_column("State", style="yellow")
        table.add_column("Health", style="magenta")

        for svc in sorted(KNOWN_SERVICES - {"all"}):
            info = status.get(svc, {})
            table.add_row(
                svc,
                info.get("status", "unknown"),
                info.get("state", "unknown"),
                info.get("health", "—"),
            )
        return table

    def list_services(self) -> Optional[bool]:
        clear_screen()
        print_header("Services Status")
        status = self.manager.get_all_status()
        if "error" in status:
            print_error(status["error"])
        else:
            console.print(self._build_table(status))
        return None

    def start_service(self) -> Optional[bool]:
        clear_screen()
        print_header("Start Service")
        svc = Prompt.ask("Service name", choices=sorted(KNOWN_SERVICES), default="all")
        result = self.manager.start(svc)
        if result["success"]:
            print_success(result["message"])
        else:
            print_error(result["message"])
        return None

    def stop_service(self) -> Optional[bool]:
        clear_screen()
        print_header("Stop Service")
        svc = Prompt.ask("Service name", choices=sorted(KNOWN_SERVICES), default="all")
        result = self.manager.stop(svc)
        if result["success"]:
            print_success(result["message"])
        else:
            print_error(result["message"])
        return None

    def restart_service(self) -> Optional[bool]:
        clear_screen()
        print_header("Restart Service")
        svc = Prompt.ask("Service name", choices=sorted(KNOWN_SERVICES), default="all")
        result = self.manager.restart(svc)
        if result["success"]:
            print_success(result["message"])
        else:
            print_error(result["message"])
        return None

    def run(self) -> Optional[bool]:
        menu = Menu("Services Menu", [
            ("0. Back", lambda: True),
            ("1. List Services", self.list_services),
            ("2. Start Service", self.start_service),
            ("3. Stop Service", self.stop_service),
            ("4. Restart Service", self.restart_service),
        ])
        return menu.run()


# ---------------------------------------------------------------------------
# Virtual Hosts Menu
# ---------------------------------------------------------------------------
class VhostsMenu:
    def __init__(self):
        self.manager = VirtualHostManager()

    def _build_table(self, vhosts: list[dict]) -> Table:
        table = Table(title="Virtual Hosts", box=box.ROUNDED)
        table.add_column("Domain", style="cyan")
        table.add_column("Root", style="green")
        table.add_column("Framework", style="yellow")
        table.add_column("Config", style="dim")
        for vh in vhosts:
            table.add_row(
                vh["domain"],
                vh.get("root", "—"),
                vh.get("framework", "php"),
                vh.get("config_path", "—"),
            )
        return table

    def list_vhosts(self) -> Optional[bool]:
        clear_screen()
        print_header("Virtual Hosts")
        vhosts = self.manager.list_all()
        if vhosts:
            console.print(self._build_table(vhosts))
        else:
            print_info("No virtual hosts configured.")
        return None

    def create_vhost(self) -> Optional[bool]:
        clear_screen()
        print_header("Create Virtual Host")
        domain = Prompt.ask("Domain (e.g., myapp.local)")
        ok, err = validate_domain(domain)
        if not ok:
            print_error(err)
            return None

        framework = Prompt.ask("Framework", choices=list(SUPPORTED_FRAMEWORKS), default="php")
        root = Prompt.ask("Web root (relative to ./projects, optional)", default="")

        result = self.manager.create(domain, root=root or None, framework=framework)
        if result["success"]:
            print_success(f"Created vhost for {domain}")
            for w in result.get("warnings", []):
                print_warning(w)
        else:
            print_error(result["warnings"][0] if result.get("warnings") else "Creation failed")
        return None

    def delete_vhost(self) -> Optional[bool]:
        clear_screen()
        print_header("Delete Virtual Host")
        vhosts = self.manager.list_all()
        if not vhosts:
            print_info("No virtual hosts to delete.")
            return None

        console.print(self._build_table(vhosts))
        domain = Prompt.ask("Domain to delete")
        if not confirm_action(f"Delete virtual host {domain}?"):
            return None

        remove_files = confirm_action("Also remove project files?", default=False)
        result = self.manager.delete(domain, remove_files=remove_files)
        if result["success"]:
            print_success(f"Deleted vhost for {domain}")
            for w in result.get("warnings", []):
                print_warning(w)
        else:
            print_error(result["warnings"][0] if result.get("warnings") else "Deletion failed")
        return None

    def run(self) -> Optional[bool]:
        menu = Menu("Virtual Hosts Menu", [
            ("0. Back", lambda: True),
            ("1. List Virtual Hosts", self.list_vhosts),
            ("2. Create Virtual Host", self.create_vhost),
            ("3. Delete Virtual Host", self.delete_vhost),
        ])
        return menu.run()


# ---------------------------------------------------------------------------
# SSL Menu
# ---------------------------------------------------------------------------
class SSLMenu:
    def __init__(self):
        self.manager = SSLManager()

    def _build_table(self, certs: list[dict]) -> Table:
        table = Table(title="SSL Certificates", box=box.ROUNDED)
        table.add_column("Domain", style="cyan")
        table.add_column("Cert Path", style="green")
        table.add_column("Key Path", style="yellow")
        table.add_column("Exists", style="magenta")
        for c in certs:
            table.add_row(
                c["domain"],
                c["cert_path"],
                c["key_path"],
                "✓" if c["exists"] else "✗",
            )
        return table

    def list_certs(self) -> Optional[bool]:
        clear_screen()
        print_header("SSL Certificates")
        certs = self.manager.list_certs()
        if certs:
            console.print(self._build_table(certs))
        else:
            print_info("No certificates found.")
        return None

    def cert_status(self) -> Optional[bool]:
        clear_screen()
        print_header("Certificate Status")
        domain = Prompt.ask("Domain")
        ok, err = validate_domain(domain)
        if not ok:
            print_error(err)
            return None
        status = self.manager.get_cert_status(domain)
        if status.get("success"):
            console.print(Panel.fit(
                f"Domain: {status['domain']}\n"
                f"Cert: {status['cert_path']}\n"
                f"Key: {status['key_path']}\n"
                f"Exists: {status['exists']}\n"
                f"Expires: {status.get('not_after', 'unknown')}\n"
                f"Expired: {status.get('expired', 'unknown')}",
                title="Certificate Status",
                border_style="green" if not status.get("expired") else "red",
            ))
        else:
            print_error(status.get("message", "Unknown error"))
        return None

    def create_mkcert(self) -> Optional[bool]:
        clear_screen()
        print_header("Create mkcert Certificate")
        domain = Prompt.ask("Domain")
        ok, err = validate_domain(domain)
        if not ok:
            print_error(err)
            return None
        result = self.manager.create_mkcert(domain)
        if result["success"]:
            print_success(result["message"])
            for w in result.get("warnings", []):
                print_warning(w)
        else:
            print_error(result["message"])
        return None

    def create_letsencrypt(self) -> Optional[bool]:
        clear_screen()
        print_header("Create Let's Encrypt Certificate")
        domain = Prompt.ask("Domain")
        ok, err = validate_domain(domain)
        if not ok:
            print_error(err)
            return None
        email = Prompt.ask("Email for Let's Encrypt")
        mode = Prompt.ask("Mode", choices=["standalone", "webroot"], default="standalone")
        webroot = None
        if mode == "webroot":
            webroot = Prompt.ask("Webroot path")
        result = self.manager.create_letsencrypt(domain, email, mode=mode, webroot_path=webroot)
        if result["success"]:
            print_success(result["message"])
            for w in result.get("warnings", []):
                print_warning(w)
        else:
            print_error(result["message"])
        return None

    def enable_ssl(self) -> Optional[bool]:
        clear_screen()
        print_header("Enable SSL for Virtual Host")
        domain = Prompt.ask("Domain")
        ok, err = validate_domain(domain)
        if not ok:
            print_error(err)
            return None
        redirect = confirm_action("Redirect HTTP to HTTPS?", default=True)
        result = self.manager.enable_vhost_ssl(domain, redirect_http=redirect)
        if result["success"]:
            print_success(result["message"])
            for w in result.get("warnings", []):
                print_warning(w)
        else:
            print_error(result["message"])
        return None

    def run(self) -> Optional[bool]:
        menu = Menu("SSL Menu", [
            ("0. Back", lambda: True),
            ("1. List Certificates", self.list_certs),
            ("2. Certificate Status", self.cert_status),
            ("3. Create mkcert Certificate", self.create_mkcert),
            ("4. Create Let's Encrypt Certificate", self.create_letsencrypt),
            ("5. Enable SSL for Vhost", self.enable_ssl),
        ])
        return menu.run()


# ---------------------------------------------------------------------------
# RDS Tunnel Menu
# ---------------------------------------------------------------------------
class RDSMenu:
    def __init__(self):
        self.tunnel = RDSTunnel()

    def status(self) -> Optional[bool]:
        clear_screen()
        print_header("RDS Tunnel Status")
        status = self.tunnel.get_status()
        console.print(Panel.fit(
            f"Connected: {status['connected']}\n"
            f"Local Port: {status['local_port']}\n"
            f"RDS Host: {status['rds_host']}\n"
            f"RDS Port: {status['rds_port']}\n"
            f"EC2 Host: {status['ec2_host']}\n"
            f"EC2 User: {status['ec2_user']}\n"
            f"Transport Active: {status['transport_active']}",
            title="Tunnel Status",
            border_style="green" if status["connected"] else "red",
        ))
        return None

    def connect(self) -> Optional[bool]:
        clear_screen()
        print_header("Connect RDS Tunnel")
        ec2_host = Prompt.ask("EC2 Host")
        ec2_user = Prompt.ask("EC2 User", default="ec2-user")
        ec2_key = Prompt.ask("SSH Key Path")
        rds_host = Prompt.ask("RDS Host")
        rds_port = IntPrompt.ask("RDS Port", default=DEFAULT_RDS_PORT)
        local_port = IntPrompt.ask("Local Port", default=DEFAULT_LOCAL_PORT)

        err = validate_connect_params(ec2_host, ec2_user, ec2_key, rds_host, rds_port, local_port)
        if err:
            print_error(err)
            return None

        print_info("Connecting...")
        result = self.tunnel.connect(
            ec2_host=ec2_host,
            ec2_user=ec2_user,
            ec2_key_path=ec2_key,
            rds_host=rds_host,
            rds_port=rds_port,
            local_port=local_port,
        )
        if result["success"]:
            print_success(result["message"])
        else:
            print_error(result["message"])
        return None

    def disconnect(self) -> Optional[bool]:
        clear_screen()
        print_header("Disconnect RDS Tunnel")
        if not self.tunnel.is_connected():
            print_info("No active tunnel.")
            return None
        if confirm_action("Disconnect tunnel?"):
            result = self.tunnel.disconnect()
            print_success(result["message"])
        return None

    def run(self) -> Optional[bool]:
        menu = Menu("RDS Tunnel Menu", [
            ("0. Back", lambda: True),
            ("1. Status", self.status),
            ("2. Connect", self.connect),
            ("3. Disconnect", self.disconnect),
        ])
        return menu.run()


# ---------------------------------------------------------------------------
# Backups Menu
# ---------------------------------------------------------------------------
class BackupsMenu:
    def __init__(self):
        self.manager = BackupManager()

    def _build_table(self, backups: list[dict]) -> Table:
        table = Table(title="Backups", box=box.ROUNDED)
        table.add_column("ID", style="cyan")
        table.add_column("Timestamp", style="green")
        table.add_column("Database", style="yellow")
        table.add_column("Size", style="magenta")
        table.add_column("Description", style="dim")
        for b in backups:
            size_mb = b.get("size_bytes", 0) / (1024 * 1024)
            table.add_row(
                b.get("id", "—"),
                b.get("timestamp", "—"),
                b.get("database", "—"),
                f"{size_mb:.1f} MB",
                b.get("description", ""),
            )
        return table

    def list_backups(self) -> Optional[bool]:
        clear_screen()
        print_header("Database Backups")
        backups = self.manager.list_backups()
        if backups:
            console.print(self._build_table(backups))
        else:
            print_info("No backups found.")
        return None

    def create_backup(self) -> Optional[bool]:
        clear_screen()
        print_header("Create Backup")
        database = Prompt.ask("Database (or 'all')", default="all")
        description = Prompt.ask("Description (optional)", default="")
        print_info("Creating backup...")
        result = self.manager.backup(database=database, description=description)
        if result["success"]:
            print_success(f"Backup created: {result['backup_id']}")
        else:
            print_error(result["message"])
        return None

    def restore_backup(self) -> Optional[bool]:
        clear_screen()
        print_header("Restore Backup")
        backups = self.manager.list_backups()
        if not backups:
            print_info("No backups available.")
            return None
        console.print(self._build_table(backups))
        backup_id = Prompt.ask("Backup ID to restore")
        database = Prompt.ask("Target database (optional)", default="")
        if not confirm_action(f"Restore backup {backup_id}? This will overwrite data!"):
            return None
        print_info("Restoring...")
        result = self.manager.restore(backup_id, database=database or None)
        if result["success"]:
            print_success(result["message"])
        else:
            print_error(result["message"])
        return None

    def delete_backup(self) -> Optional[bool]:
        clear_screen()
        print_header("Delete Backup")
        backups = self.manager.list_backups()
        if not backups:
            print_info("No backups to delete.")
            return None
        console.print(self._build_table(backups))
        backup_id = Prompt.ask("Backup ID to delete")
        if not confirm_action(f"Permanently delete backup {backup_id}?"):
            return None
        # BackupManager doesn't have a delete method; we'll need to add it or do it manually
        # For now, just inform the user
        print_warning("Delete not implemented in BackupManager yet. Remove manually from backups/")
        return None

    def run(self) -> Optional[bool]:
        menu = Menu("Backups Menu", [
            ("0. Back", lambda: True),
            ("1. List Backups", self.list_backups),
            ("2. Create Backup", self.create_backup),
            ("3. Restore Backup", self.restore_backup),
            ("4. Delete Backup", self.delete_backup),
        ])
        return menu.run()


# ---------------------------------------------------------------------------
# Logs Menu
# ---------------------------------------------------------------------------
class LogsMenu:
    def __init__(self):
        self.aggregator = LogAggregator()

    def _build_table(self, entries: list[dict]) -> Table:
        table = Table(title="Log Entries", box=box.ROUNDED)
        table.add_column("Service", style="cyan", no_wrap=True)
        table.add_column("Message", style="white", overflow="fold")
        for e in entries:
            svc = e.get("service") or "—"
            table.add_row(svc, e.get("message", e.get("raw", "")))
        return table

    def view_logs(self) -> Optional[bool]:
        clear_screen()
        print_header("View Logs")
        service = Prompt.ask("Service", choices=sorted(VALID_TARGETS), default="all")
        lines = IntPrompt.ask("Lines", default=DEFAULT_LINES)
        result = self.aggregator.get_logs(service, lines=lines)
        if result["success"]:
            if result["entries"]:
                console.print(self._build_table(result["entries"]))
            else:
                print_info("No log entries.")
            if result.get("truncated"):
                print_warning(f"Output truncated to {lines} lines.")
        else:
            print_error(result["message"])
        return None

    def follow_logs(self) -> Optional[bool]:
        clear_screen()
        print_header("Follow Logs (Ctrl+C to stop)")
        service = Prompt.ask("Service", choices=sorted(VALID_TARGETS), default="all")
        print_info(f"Following logs for {service}... Press Ctrl+C to stop.")
        try:
            for line in self.aggregator.stream_logs(service):
                console.print(line)
        except KeyboardInterrupt:
            print_info("\nStopped following.")
        except ValueError as e:
            print_error(str(e))
        return None

    def run(self) -> Optional[bool]:
        menu = Menu("Logs Menu", [
            ("0. Back", lambda: True),
            ("1. View Logs (tail)", self.view_logs),
            ("2. Follow Logs (live)", self.follow_logs),
        ])
        return menu.run()


# ---------------------------------------------------------------------------
# Main Menu
# ---------------------------------------------------------------------------
class MainMenu:
    def __init__(self):
        self.services = ServicesMenu()
        self.vhosts = VhostsMenu()
        self.ssl = SSLMenu()
        self.rds = RDSMenu()
        self.backups = BackupsMenu()
        self.logs = LogsMenu()

    def run(self) -> None:
        menu = Menu("DevStack TUI", [
            ("0. Exit", lambda: True),
            ("1. Services", self.services.run),
            ("2. Virtual Hosts", self.vhosts.run),
            ("3. SSL Certificates", self.ssl.run),
            ("4. RDS Tunnel", self.rds.run),
            ("5. Backups", self.backups.run),
            ("6. Logs", self.logs.run),
        ])
        menu.run()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> int:
    try:
        MainMenu().run()
        return 0
    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted.[/yellow]")
        return 130
    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())