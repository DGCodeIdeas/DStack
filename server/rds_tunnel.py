"""RDS SSH tunnel manager (local <-> EC2 <-> RDS).

Provides :class:`RDSTunnel`, a thin wrapper around ``paramiko`` that opens an
SSH connection to an EC2 bastion host and exposes a local TCP port that
forwards traffic to a remote RDS endpoint via an SSH ``direct-tcpip`` channel.

This is the canonical paramiko ``forward.py`` pattern implemented without any
external ``sshtunnel`` dependency. The forwarder and the auto-reconnect watcher
are kept as small, independently testable units.

No live EC2/RDS host is required to import or unit-test this module: input
validation, status reporting, idempotent teardown and the channel-opening logic
can all be exercised with a mocked :class:`paramiko.Transport`.
"""

from __future__ import annotations

import logging
import socket
import socketserver
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

import paramiko

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SSH_PORT = 22
DEFAULT_RDS_PORT = 3306
DEFAULT_LOCAL_PORT = 3307

# Bounds for the auto-reconnect watcher (no infinite tight loop).
MAX_RECONNECT_RETRIES = 5
RECONNECT_BACKOFF_BASE = 5.0          # seconds
RECONNECT_BACKOFF_MAX = 60.0          # seconds

# Socket / channel timeouts.
SOCKET_TIMEOUT = 30.0
CHANNEL_TIMEOUT = 30.0
CHANNEL_CONNECT_TIMEOUT = 15.0


# ---------------------------------------------------------------------------
# Pure / testable helpers
# ---------------------------------------------------------------------------
def validate_connect_params(
    ec2_host: Any,
    ec2_user: Any,
    ec2_key_path: Any,
    rds_host: Any,
    rds_port: Any = DEFAULT_RDS_PORT,
    local_port: Any = DEFAULT_LOCAL_PORT,
) -> Optional[str]:
    """Validate the arguments for :meth:`RDSTunnel.connect`.

    Returns a human-readable error string when validation fails, otherwise
    ``None`` (meaning the parameters are acceptable).
    """
    # String fields must be non-empty strings.
    for name, value in (
        ("ec2_host", ec2_host),
        ("ec2_user", ec2_user),
        ("rds_host", rds_host),
    ):
        if not isinstance(value, str) or not value.strip():
            return f"{name} must be a non-empty string"

    if not isinstance(ec2_key_path, str) or not ec2_key_path.strip():
        return "ec2_key_path must be a non-empty string"

    key_file = Path(ec2_key_path)
    if not key_file.exists():
        return f"ec2_key_path does not exist: {ec2_key_path}"
    if not key_file.is_file():
        return f"ec2_key_path is not a file: {ec2_key_path}"

    # Ports must be integers in the valid TCP range.
    for name, value in (("rds_port", rds_port), ("local_port", local_port)):
        if not isinstance(value, int) or isinstance(value, bool):
            return f"{name} must be an integer"
        if not (1 <= value <= 65535):
            return f"{name} must be between 1 and 65535, got {value}"

    return None


def open_direct_tcpip_channel(
    transport: paramiko.Transport,
    remote_host: str,
    remote_port: int,
    peer_addr: tuple,
    timeout: float = CHANNEL_CONNECT_TIMEOUT,
) -> paramiko.Channel:
    """Open a ``direct-tcpip`` channel to ``(remote_host, remote_port)``.

    This is the core forwarding primitive. It is a standalone function so it
    can be unit-tested with a mock :class:`paramiko.Transport` without needing
    a real socket.

    ``peer_addr`` is the originating client's ``(host, port)`` tuple, as
    required by the SSH protocol for the channel originator information.
    """
    chan = transport.open_channel(
        "direct-tcpip",
        (remote_host, remote_port),
        peer_addr,
        timeout=timeout,
    )
    chan.settimeout(CHANNEL_TIMEOUT)
    return chan


def pump(src, dst, chunk_size: int = 4096) -> None:
    """Bidirectional byte pump between two socket-like objects.

    Reads from ``src`` and writes to ``dst`` until ``src`` hits EOF or raises.
    Used by the forwarder handler to shuttle bytes between the local client and
    the remote RDS channel.
    """
    while True:
        try:
            data = src.recv(chunk_size)
        except (socket.error, EOFError, OSError):
            break
        if not data:
            break
        try:
            dst.sendall(data)
        except (socket.error, EOFError, OSError):
            break


# ---------------------------------------------------------------------------
# Forwarding server
# ---------------------------------------------------------------------------
class ForwardHandler(socketserver.StreamRequestHandler):
    """Per-connection handler: bridges a local socket to a remote RDS channel.

    The owning :class:`ForwardServer` carries the live ``transport`` plus the
    remote ``(host, port)`` target, so the handler stays stateless and small.
    """

    def handle(self) -> None:  # noqa: D401 - imperative style is fine here
        server = self.server
        transport = server.transport
        if transport is None or not transport.is_active():
            logger.warning("ForwardHandler: transport not active; refusing connection")
            return

        try:
            peer = self.request.getpeername()
        except (socket.error, OSError):
            peer = ("127.0.0.1", 0)

        try:
            chan = open_direct_tcpip_channel(
                transport,
                server.remote_host,
                server.remote_port,
                peer,
            )
        except paramiko.SSHException as exc:
            logger.warning("ForwardHandler: failed to open channel: %s", exc)
            return
        except (socket.error, EOFError) as exc:
            logger.warning("ForwardHandler: channel socket error: %s", exc)
            return

        try:
            # Bridge local socket <-> remote channel in both directions.
            t = threading.Thread(target=pump, args=(chan, self.request), daemon=True)
            t.start()
            pump(self.request, chan)
        finally:
            try:
                chan.close()
            except Exception:  # pragma: no cover - best effort cleanup
                pass


class ForwardServer(socketserver.ThreadingTCPServer):
    """A threaded TCP server that forwards each connection to a remote host.

    The server itself holds the SSH ``transport`` and the remote target so the
    (per-request) :class:`ForwardHandler` can remain a thin, stateless bridge.
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple,
        transport: paramiko.Transport,
        remote_host: str,
        remote_port: int,
        handler=ForwardHandler,
    ) -> None:
        super().__init__(server_address, handler)
        self.transport = transport
        self.remote_host = remote_host
        self.remote_port = remote_port


# ---------------------------------------------------------------------------
# Auto-reconnect watcher
# ---------------------------------------------------------------------------
class ReconnectWatcher:
    """Lightweight watcher that re-establishes a dropped SSH transport.

    Runs in its own daemon thread. It polls ``transport.is_active()`` and, if
    the connection has dropped, attempts to reconnect using the stored
    connection parameters, with a bounded retry count and exponential backoff.
    It never spins in a tight loop.
    """

    def __init__(
        self,
        tunnel: "RDSTunnel",
        max_retries: int = MAX_RECONNECT_RETRIES,
        backoff_base: float = RECONNECT_BACKOFF_BASE,
        backoff_max: float = RECONNECT_BACKOFF_MAX,
    ) -> None:
        self._tunnel = tunnel
        self._max_retries = max_retries
        self._backoff_base = backoff_base
        self._backoff_max = backoff_max
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="rds-reconnect", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        retries = 0
        backoff = self._backoff_base
        while not self._stop.is_set():
            # Sleep in small slices so stop() is responsive.
            if self._stop.wait(backoff):
                break

            if self._stop.is_set():
                break

            if not self._tunnel.is_connected():
                # Nothing to watch (disconnected on purpose).
                retries = 0
                backoff = self._backoff_base
                continue

            transport = self._tunnel._transport
            if transport is not None and transport.is_active():
                # Healthy: reset retry budget.
                retries = 0
                backoff = self._backoff_base
                continue

            # Transport dropped -> attempt reconnect.
            logger.warning("ReconnectWatcher: transport inactive, attempting reconnect")
            try:
                self._tunnel._reconnect()
                retries = 0
                backoff = self._backoff_base
                logger.info("ReconnectWatcher: reconnect succeeded")
            except Exception as exc:  # noqa: BLE001 - report and back off
                retries += 1
                logger.warning(
                    "ReconnectWatcher: reconnect attempt %d/%d failed: %s",
                    retries,
                    self._max_retries,
                    exc,
                )
                if retries >= self._max_retries:
                    logger.error("ReconnectWatcher: giving up after %d retries", retries)
                    # Stop trying; leave the tunnel in a disconnected state.
                    self._tunnel._mark_failed()
                    break
                backoff = min(backoff * 2, self._backoff_max)


# ---------------------------------------------------------------------------
# Main tunnel class
# ---------------------------------------------------------------------------
class RDSTunnel:
    """Manage an SSH tunnel from a local port to a remote RDS endpoint.

    Typical usage::

        tunnel = RDSTunnel()
        result = tunnel.connect(
            ec2_host="1.2.3.4",
            ec2_user="ec2-user",
            ec2_key_path="~/.ssh/devstack-ec2",
            rds_host="my-rds.123.us-east-1.rds.amazonaws.com",
        )
        if result["success"]:
            mysql -h 127.0.0.1 -P 3307 -u admin -p
        tunnel.disconnect()
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._transport: Optional[paramiko.Transport] = None
        self._server: Optional[ForwardServer] = None
        self._server_thread: Optional[threading.Thread] = None
        self._watcher: Optional[ReconnectWatcher] = None

        # Connection parameters (kept for status + reconnect).
        self._ec2_host: Optional[str] = None
        self._ec2_user: Optional[str] = None
        self._ec2_key_path: Optional[str] = None
        self._rds_host: Optional[str] = None
        self._rds_port: Optional[int] = None
        self._local_port: Optional[int] = None
        self._connected: bool = False

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def connect(
        self,
        ec2_host: str,
        ec2_user: str,
        ec2_key_path: str,
        rds_host: str,
        rds_port: int = DEFAULT_RDS_PORT,
        local_port: int = DEFAULT_LOCAL_PORT,
    ) -> Dict[str, Any]:
        """Open the SSH transport and start the local forwarder.

        Returns a structured result dict::

            {"success": bool, "message": str,
             "local_port": int, "rds_host": str, "rds_port": int}
        """
        # Always tear down any previous state first (idempotent start).
        self.disconnect()

        err = validate_connect_params(
            ec2_host, ec2_user, ec2_key_path, rds_host, rds_port, local_port
        )
        if err:
            return self._result(False, err, local_port, rds_host, rds_port)

        key_path = str(Path(ec2_key_path).expanduser())

        # --- Load the private key -------------------------------------
        try:
            pkey = paramiko.RSAKey.from_private_key_file(key_path)
        except paramiko.PasswordRequiredException:
            return self._result(
                False,
                "SSH key is passphrase-protected; passphrase-protected keys are "
                "not supported by this tunnel. Use an unencrypted key or an agent.",
                local_port,
                rds_host,
                rds_port,
            )
        except paramiko.SSHException as exc:
            return self._result(
                False,
                f"Failed to load SSH key {key_path}: {exc}",
                local_port,
                rds_host,
                rds_port,
            )
        except (OSError, IOError) as exc:
            return self._result(
                False,
                f"Could not read SSH key {key_path}: {exc}",
                local_port,
                rds_host,
                rds_port,
            )

        # --- Establish the SSH transport ------------------------------
        try:
            sock = socket.create_connection((ec2_host, SSH_PORT), timeout=SOCKET_TIMEOUT)
        except (socket.error, OSError) as exc:
            return self._result(
                False,
                f"Cannot reach SSH host {ec2_host}:{SSH_PORT}: {exc}",
                local_port,
                rds_host,
                rds_port,
            )

        try:
            transport = paramiko.Transport(sock)
            transport.set_socket_timeout(SOCKET_TIMEOUT)
            transport.start_client()
            transport.auth_publickey(ec2_user, pkey)
            if not transport.is_authenticated():
                raise paramiko.SSHException("Authentication rejected by the server")
        except paramiko.SSHException as exc:
            try:
                sock.close()
            except Exception:  # pragma: no cover
                pass
            return self._result(
                False,
                f"SSH connection/authentication failed: {exc}",
                local_port,
                rds_host,
                rds_port,
            )
        except (socket.error, EOFError, OSError) as exc:
            try:
                sock.close()
            except Exception:  # pragma: no cover
                pass
            return self._result(
                False,
                f"SSH handshake error with {ec2_host}: {exc}",
                local_port,
                rds_host,
                rds_port,
            )

        # --- Start the local forwarder --------------------------------
        try:
            server = ForwardServer(
                ("127.0.0.1", local_port),
                transport,
                rds_host,
                rds_port,
            )
        except (socket.error, OSError) as exc:
            transport.close()
            return self._result(
                False,
                f"Could not bind local port 127.0.0.1:{local_port}: {exc}",
                local_port,
                rds_host,
                rds_port,
            )

        server_thread = threading.Thread(
            target=server.serve_forever, name="rds-forwarder", daemon=True
        )
        server_thread.start()

        with self._lock:
            self._transport = transport
            self._server = server
            self._server_thread = server_thread
            self._ec2_host = ec2_host
            self._ec2_user = ec2_user
            self._ec2_key_path = key_path
            self._rds_host = rds_host
            self._rds_port = rds_port
            self._local_port = local_port
            self._connected = True

        # --- Start the reconnect watcher ------------------------------
        self._watcher = ReconnectWatcher(self)
        self._watcher.start()

        return self._result(
            True,
            f"Tunnel established: 127.0.0.1:{local_port} -> "
            f"{rds_host}:{rds_port} via {ec2_host}",
            local_port,
            rds_host,
            rds_port,
        )

    def disconnect(self) -> Dict[str, Any]:
        """Tear down the forwarder, transport and watcher.

        Safe to call when not connected (idempotent, never raises).
        """
        with self._lock:
            watcher = self._watcher
            server = self._server
            server_thread = self._server_thread
            transport = self._transport

            self._watcher = None
            self._server = None
            self._server_thread = None
            self._transport = None
            self._connected = False

        # Stop the watcher first so it doesn't try to reconnect mid-teardown.
        if watcher is not None:
            try:
                watcher.stop()
            except Exception:  # pragma: no cover
                pass

        if server is not None:
            try:
                server.shutdown()
                server.server_close()
            except Exception:  # pragma: no cover
                pass

        if server_thread is not None:
            try:
                server_thread.join(timeout=2.0)
            except Exception:  # pragma: no cover
                pass

        if transport is not None:
            try:
                transport.close()
            except Exception:  # pragma: no cover
                pass

        return {"success": True, "message": "Tunnel disconnected"}

    def get_status(self) -> Dict[str, Any]:
        """Return the current tunnel status as a structured dict."""
        with self._lock:
            transport_active = (
                self._transport.is_active() if self._transport is not None else False
            )
            return {
                "connected": self._connected and transport_active,
                "local_port": self._local_port,
                "rds_host": self._rds_host,
                "rds_port": self._rds_port,
                "ec2_host": self._ec2_host,
                "ec2_user": self._ec2_user,
                "transport_active": transport_active,
            }

    def is_connected(self) -> bool:
        """Return True if a transport is present and active."""
        with self._lock:
            return self._connected and (
                self._transport.is_active() if self._transport is not None else False
            )

    # ------------------------------------------------------------------
    # Internal helpers (used by the watcher)
    # ------------------------------------------------------------------
    def _reconnect(self) -> None:
        """Re-establish the SSH transport using stored parameters.

        On success, the existing forwarder server is re-pointed at the new
        transport so client connections keep working.
        """
        with self._lock:
            ec2_host = self._ec2_host
            ec2_user = self._ec2_user
            ec2_key_path = self._ec2_key_path
            rds_host = self._rds_host
            rds_port = self._rds_port
            local_port = self._local_port
            server = self._server

        if not all([ec2_host, ec2_user, ec2_key_path, rds_host, rds_port, local_port]):
            raise paramiko.SSHException("Missing connection parameters for reconnect")

        pkey = paramiko.RSAKey.from_private_key_file(ec2_key_path)
        sock = socket.create_connection((ec2_host, SSH_PORT), timeout=SOCKET_TIMEOUT)
        transport = paramiko.Transport(sock)
        transport.set_socket_timeout(SOCKET_TIMEOUT)
        transport.start_client()
        transport.auth_publickey(ec2_user, pkey)
        if not transport.is_authenticated():
            raise paramiko.SSHException("Reconnect authentication rejected")

        with self._lock:
            # Swap the transport under the forwarder server.
            if self._transport is not None:
                try:
                    self._transport.close()
                except Exception:  # pragma: no cover
                    pass
            self._transport = transport
            if server is not None:
                server.transport = transport
            self._connected = True

    def _mark_failed(self) -> None:
        """Mark the tunnel as disconnected after exhausting reconnect retries."""
        with self._lock:
            self._connected = False

    # ------------------------------------------------------------------
    # Result helper
    # ------------------------------------------------------------------
    @staticmethod
    def _result(
        success: bool, message: str, local_port: Any, rds_host: Any, rds_port: Any
    ) -> Dict[str, Any]:
        return {
            "success": success,
            "message": message,
            "local_port": local_port,
            "rds_host": rds_host,
            "rds_port": rds_port,
        }
