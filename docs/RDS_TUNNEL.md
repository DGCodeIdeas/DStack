> [!WARNING]
> This document describes the legacy Flask-based architecture and is no longer accurate.
> For current documentation, see the [Documentation Index](./README.md).

# RDS SSH Tunnel (Local ↔ EC2 ↔ RDS)

This guide explains how to use the DevStack **RDS tunnel** feature, which opens
an SSH tunnel from your local machine to a remote Amazon RDS instance through an
EC2 bastion host. The tunnel is implemented with [`paramiko`](https://www.paramiko.org/)
(no external `sshtunnel` dependency) and exposed via the Flask API in
[`server/app.py`](../server/app.py) (see `RDSTunnel` in
[`server/rds_tunnel.py`](../server/rds_tunnel.py)).

```
your laptop                EC2 bastion                Amazon RDS
-----------                -----------                ----------
mysql client  ──local──▶  127.0.0.1:3307  ──SSH──▶  rds.host:3306
            (direct-tcpip channel over the SSH transport)
```

> **Scope:** This is a focused, how-to document. The full documentation set is
> covered in a later subtask.

---

## 1. Generate an SSH key pair

Create a dedicated RSA key for the bastion host (do **not** reuse a key with a
passphrase — the tunnel does not support encrypted keys):

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/devstack-ec2 -N ""
```

This produces:

* `~/.ssh/devstack-ec2` — your **private** key (never share or commit this).
* `~/.ssh/devstack-ec2.pub` — the **public** key to install on the EC2 host.

---

## 2. Authorize the public key on the EC2 instance

Add the public key to the bastion's `authorized_keys` so the tunnel can
authenticate:

```bash
# Easiest: copy the public key to the EC2 instance
ssh-copy-id -i ~/.ssh/devstack-ec2.pub ec2-user@<EC2_PUBLIC_IP>

# Or, in the AWS console / SSM, append the .pub contents to:
#   ~/.ssh/authorized_keys   (for the relevant user, e.g. ec2-user)
```

---

## 3. Configure security groups

Two network rules are required for the tunnel to work end-to-end:

1. **EC2 security group** — allow inbound **TCP 22 (SSH)** from your laptop's
   public IP (or a CIDR you control). Never open 22 to `0.0.0.0/0` in
   production.
2. **RDS security group** — allow inbound from the **EC2 instance's security
   group** (or its private IP) on the RDS port (usually **3306** for MySQL /
   **5432** for PostgreSQL). RDS is typically only reachable from inside the
   VPC, which is why the EC2 host acts as the bastion.

---

## 4. Start the tunnel via the API

`POST /api/rds/tunnel/start` with a JSON body:

| Field           | Type   | Required | Default | Notes                                  |
| --------------- | ------ | -------- | ------- | -------------------------------------- |
| `ec2_host`      | string | yes      | —       | Public IP / DNS of the EC2 bastion     |
| `ec2_user`      | string | yes      | —       | SSH user (e.g. `ec2-user`)             |
| `ec2_key_path`  | string | yes      | —       | Path to the **private** key on disk    |
| `rds_host`      | string | yes      | —       | RDS endpoint hostname                  |
| `rds_port`      | int    | no       | `3306`  | Remote RDS port                        |
| `local_port`    | int    | no       | `3307`  | Local port to bind (`127.0.0.1`)       |

```bash
curl -s -X POST http://localhost:5000/api/rds/tunnel/start \
  -H 'Content-Type: application/json' \
  -d '{
    "ec2_host": "203.0.113.10",
    "ec2_user": "ec2-user",
    "ec2_key_path": "/home/you/.ssh/devstack-ec2",
    "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
    "rds_port": 3306,
    "local_port": 3307
  }'
```

Success response:

```json
{
  "success": true,
  "message": "Tunnel established: 127.0.0.1:3307 -> my-rds...:3306 via 203.0.113.10",
  "local_port": 3307,
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306
}
```

If the host is unreachable or the key is invalid, you get a clean structured
error (HTTP 400) instead of a crash:

```json
{
  "success": false,
  "message": "Cannot reach SSH host 203.0.113.10:22: [Errno 113] No route to host",
  "local_port": 3307,
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306
}
```

---

## 5. Connect locally

Once the tunnel is up, point your database client at the **local** forwarded
port. Traffic is transparently shuttled to RDS over the SSH channel:

```bash
mysql -h 127.0.0.1 -P 3307 -u admin -p
```

Or with a connection string:

```bash
mysql://admin:PASSWORD@127.0.0.1:3307/mydb
```

---

## 6. Check status / stop the tunnel

```bash
# Status (works whether connected or not)
curl -s http://localhost:5000/api/rds/tunnel/status | jq
# -> {"connected": true, "local_port": 3307, "rds_host": "...",
#     "rds_port": 3306, "ec2_host": "203.0.113.10",
#     "ec2_user": "ec2-user", "transport_active": true}

# Stop the tunnel (safe to call even if not connected)
curl -s -X POST http://localhost:5000/api/rds/tunnel/stop
```

---

## Notes & limitations

* **No passphrase-protected keys.** The tunnel loads the key with
  `paramiko.RSAKey.from_private_key_file`; an encrypted key returns a clear
  error. Use an agent or an unencrypted key for automation.
* **Auto-reconnect.** A lightweight watcher thread monitors the SSH transport
  and attempts a bounded number of reconnects (with exponential backoff) if the
  connection drops. It will not spin forever.
* **Local-only bind.** The forwarder binds to `127.0.0.1` only, so the tunnel is
  not exposed to the network.
* **No live host in the sandbox.** The implementation is designed to fail
  gracefully (structured error) when the EC2/RDS endpoint is unreachable; unit
  tests cover validation, status, teardown and the channel-opening logic with a
  mocked transport.
