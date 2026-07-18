"""Unit tests for the RDSTunnel module.

These tests do not require a live EC2 host or RDS endpoint. They exercise:

* input validation (rejects bad parameters),
* ``get_status()`` returning a disconnected state initially,
* ``disconnect()`` being safe when nothing is connected,
* the forwarder channel-opening logic (mocked ``paramiko.Transport`` asserts
  ``open_channel("direct-tcpip", ...)`` is called with the right remote address),
* the forwarder handler / server plumbing compiles and wires up correctly.

Run with::

    python3 server/test_rds_tunnel.py
"""

from __future__ import annotations

import os
import socket
import threading
from unittest.mock import MagicMock

from rds_tunnel import (
    ForwardServer,
    RDSTunnel,
    open_direct_tcpip_channel,
    validate_connect_params,
)


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"FAILED: {message}")
    print(f"  ok: {message}")


def _make_throwaway_key() -> str:
    """Generate a real (unencrypted) RSA key file and return its path.

    Used by the unreachable-host test so key loading succeeds and the failure
    happens at the network layer (as it would with a genuine key).
    """
    import tempfile

    import paramiko

    key = paramiko.RSAKey.generate(2048)
    fd, path = tempfile.mkstemp(prefix="rds-tunnel-test-", suffix=".key")
    with os.fdopen(fd, "w") as fh:
        key.write_private_key(fh)
    os.chmod(path, 0o600)
    return path


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
def test_validate_rejects_empty_strings() -> None:
    err = validate_connect_params("", "ec2-user", "/tmp/key", "rds.host")
    _assert(err is not None, "empty ec2_host is rejected")

    err = validate_connect_params("1.2.3.4", "", "/tmp/key", "rds.host")
    _assert(err is not None, "empty ec2_user is rejected")

    err = validate_connect_params("1.2.3.4", "ec2-user", "/tmp/key", "")
    _assert(err is not None, "empty rds_host is rejected")


def test_validate_rejects_missing_key_file() -> None:
    err = validate_connect_params(
        "1.2.3.4", "ec2-user", "/no/such/key-file", "rds.host"
    )
    _assert(err is not None, "non-existent ec2_key_path is rejected")
    _assert("does not exist" in err, "error mentions missing key path")


def test_validate_rejects_bad_ports() -> None:
    err = validate_connect_params("1.2.3.4", "ec2-user", __file__, "rds.host", rds_port=0)
    _assert(err is not None, "rds_port=0 is rejected (out of range)")

    err = validate_connect_params(
        "1.2.3.4", "ec2-user", __file__, "rds.host", local_port=70000
    )
    _assert(err is not None, "local_port=70000 is rejected (out of range)")

    err = validate_connect_params(
        "1.2.3.4", "ec2-user", __file__, "rds.host", rds_port="not-an-int"
    )
    _assert(err is not None, "non-int rds_port is rejected")


def test_validate_accepts_valid_params() -> None:
    # __file__ exists and is a file, so it passes the key-path check.
    err = validate_connect_params(
        "1.2.3.4", "ec2-user", __file__, "rds.host", rds_port=3306, local_port=3307
    )
    _assert(err is None, "valid parameters pass validation")


# ---------------------------------------------------------------------------
# Status / lifecycle safety
# ---------------------------------------------------------------------------
def test_status_disconnected_initially() -> None:
    tunnel = RDSTunnel()
    status = tunnel.get_status()
    _assert(status["connected"] is False, "initial status is not connected")
    _assert(status["transport_active"] is False, "initial transport_active is False")
    _assert(status["local_port"] is None, "local_port is None when disconnected")
    _assert(status["rds_host"] is None, "rds_host is None when disconnected")
    _assert(status["ec2_host"] is None, "ec2_host is None when disconnected")
    _assert(status["ec2_user"] is None, "ec2_user is None when disconnected")


def test_disconnect_safe_when_not_connected() -> None:
    tunnel = RDSTunnel()
    result = tunnel.disconnect()
    _assert(result["success"] is True, "disconnect() succeeds when not connected")
    # Calling it again must still be safe (idempotent).
    result2 = tunnel.disconnect()
    _assert(result2["success"] is True, "disconnect() is idempotent")


def test_connect_returns_failure_for_unreachable_host() -> None:
    tunnel = RDSTunnel()
    key_path = _make_throwaway_key()
    try:
        # 192.0.2.1 is TEST-NET-1 (RFC 5737) - non-routable, so it will fail fast.
        result = tunnel.connect(
            ec2_host="192.0.2.1",
            ec2_user="ec2-user",
            ec2_key_path=key_path,  # valid key, so failure happens at network layer
            rds_host="rds.test.amazonaws.com",
            rds_port=3306,
            local_port=3307,
        )
    finally:
        os.remove(key_path)
    _assert(result["success"] is False, "connect to unreachable host fails cleanly")
    _assert("Cannot reach" in result["message"], "error mentions unreachable host")
    status = tunnel.get_status()
    _assert(status["connected"] is False, "tunnel remains disconnected after failure")


# ---------------------------------------------------------------------------
# Forwarder channel-opening logic (mocked transport)
# ---------------------------------------------------------------------------
def test_open_direct_tcpip_channel_calls_transport() -> None:
    transport = MagicMock()
    fake_chan = MagicMock()
    transport.open_channel.return_value = fake_chan

    chan = open_direct_tcpip_channel(
        transport,
        remote_host="my-rds.123.us-east-1.rds.amazonaws.com",
        remote_port=3306,
        peer_addr=("127.0.0.1", 54321),
    )

    # Assert the channel was opened with the canonical direct-tcpip args.
    transport.open_channel.assert_called_once_with(
        "direct-tcpip",
        ("my-rds.123.us-east-1.rds.amazonaws.com", 3306),
        ("127.0.0.1", 54321),
        timeout=15.0,
    )
    _assert(chan is fake_chan, "returns the channel produced by the transport")
    fake_chan.settimeout.assert_called_once()


def test_forward_server_wires_transport_and_remote() -> None:
    transport = MagicMock()
    server = ForwardServer(
        ("127.0.0.1", 0),
        transport,
        "rds.host",
        3306,
    )
    _assert(server.transport is transport, "server holds the transport")
    _assert(server.remote_host == "rds.host", "server holds remote_host")
    _assert(server.remote_port == 3306, "server holds remote_port")
    _assert(server.allow_reuse_address is True, "server allows address reuse")
    server.server_close()


def test_forward_handler_opens_channel_on_accept() -> None:
    """Drive the handler with mocks and assert it opens a direct-tcpip channel."""
    from rds_tunnel import ForwardHandler

    transport = MagicMock()
    fake_chan = MagicMock()
    fake_chan.recv.return_value = b""  # make pump() exit immediately
    transport.open_channel.return_value = fake_chan
    transport.is_active.return_value = True

    server = ForwardServer(("127.0.0.1", 0), transport, "rds.host", 3306)

    # Minimal request stub: getpeername + recv (returns b"" so pump exits).
    request = MagicMock()
    request.getpeername.return_value = ("127.0.0.1", 55555)
    request.recv.return_value = b""

    handler = ForwardHandler(request, ("127.0.0.1", 55555), server)

    transport.open_channel.assert_called_once_with(
        "direct-tcpip",
        ("rds.host", 3306),
        ("127.0.0.1", 55555),
        timeout=15.0,
    )
    fake_chan.close.assert_called()
    server.server_close()


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
def main() -> None:
    print("Running RDSTunnel unit tests...")
    test_validate_rejects_empty_strings()
    test_validate_rejects_missing_key_file()
    test_validate_rejects_bad_ports()
    test_validate_accepts_valid_params()
    test_status_disconnected_initially()
    test_disconnect_safe_when_not_connected()
    test_connect_returns_failure_for_unreachable_host()
    test_open_direct_tcpip_channel_calls_transport()
    test_forward_server_wires_transport_and_remote()
    test_forward_handler_opens_channel_on_accept()
    print("All RDSTunnel tests passed.")


if __name__ == "__main__":
    main()
