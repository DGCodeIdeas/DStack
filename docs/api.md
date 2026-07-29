# API Reference

This document describes the DStack Panel REST API. All endpoints are prefixed with `/api` and return JSON unless noted otherwise.

---

## Base URL

```
http://localhost:5000/api
```

For production behind nginx:

```
https://panel.chadadigital.com/api
```

---

## Authentication

All API endpoints require authentication via Laravel session cookies. Log in through the panel UI at `/login`, or use the `/login` endpoint with HTTP basic auth for programmatic access.

```
Authorization: Basic base64(email:password)
```

---

## Common Response Format

### Success Response

```json
{
  "success": true,
  "message": "Operation completed",
  "data": { ... }
}
```

### Error Response

```json
{
  "success": false,
  "message": "Human-readable error description",
  "errors": { ... }
}
```

---

## Health & Diagnostics

### `GET /up`

Laravel health check probe. Used by load balancers and orchestrators.

**Response:** `200 OK` with HTML or JSON depending on `Accept` header.

### `GET /api/health`

Panel health check.

**Response:**
```json
{
  "status": "ok",
  "version": "1.2.3"
}
```

---

## Services Management

### `GET /api/services`

Get status of all Docker Compose services.

**Response:**
```json
{
  "success": true,
  "data": [
    {
      "name": "nginx",
      "state": "running",
      "status": "Up 5 minutes (healthy)"
    },
    {
      "name": "php",
      "state": "running",
      "status": "Up 5 minutes"
    }
  ]
}
```

**Example:**
```bash
curl -s https://panel.chadadigital.com/api/services | jq
```

---

### `POST /api/services/{service}/{action}`

Control a Docker service.

| Parameter | Type | Values |
|-----------|------|--------|
| `service` | string | `nginx`, `php`, `mysql`, `redis`, `phpmyadmin`, `all` |
| `action` | string | `start`, `stop`, `restart` |

**Response:**
```json
{
  "success": true,
  "message": "Service nginx restarted"
}
```

**Examples:**
```bash
curl -X POST https://panel.chadadigital.com/api/services/nginx/restart
curl -X POST https://panel.chadadigital.com/api/services/all/stop
```

---

## Virtual Hosts

### `GET /api/vhosts`

List all configured virtual hosts.

**Response:**
```json
{
  "success": true,
  "data": [
    {
      "domain": "testapp.local",
      "framework": "laravel",
      "root": "/opt/dstack-panel/projects/testapp.local/public",
      "config_path": "/opt/dstack-panel/docker/vhosts/testapp.local.conf"
    }
  ]
}
```

---

### `POST /api/vhosts`

Create a new virtual host.

**Request Body:**
```json
{
  "domain": "myapp.local",
  "framework": "laravel",
  "root": "/opt/dstack-panel/projects/myapp.local/public"
}
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `domain` | Yes | string | — | Valid hostname (e.g., `myapp.local`) |
| `framework` | No | string | `php` | `php`, `laravel`, `symfony`, `wordpress`, `static` |
| `root` | No | string | Auto | Host-side web root path |

**Response:**
```json
{
  "success": true,
  "domain": "myapp.local",
  "framework": "laravel",
  "root": "/opt/dstack-panel/projects/myapp.local/public",
  "config_path": "/opt/dstack-panel/docker/vhosts/myapp.local.conf"
}
```

**Examples:**
```bash
# Create Laravel vhost
curl -X POST https://panel.chadadigital.com/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local", "framework": "laravel"}'

# Create vhost with custom root
curl -X POST https://panel.chadadigital.com/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "api.example.com", "root": "/opt/dstack-panel/projects/api/public"}'
```

---

### `DELETE /api/vhosts/{domain}`

Delete a virtual host.

**Query Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `remove_files` | boolean | `false` | Also delete the project directory |

**Response:**
```json
{
  "success": true,
  "domain": "myapp.local",
  "removed_config": "/opt/dstack-panel/docker/vhosts/myapp.local.conf",
  "removed_files": "/opt/dstack-panel/projects/myapp.local"
}
```

---

## SSL Certificates

### `GET /api/ssl`

List all SSL certificates.

**Response:**
```json
{
  "success": true,
  "data": [
    {
      "domain": "myapp.local",
      "cert_path": "/opt/dstack-panel/docker/ssl/myapp.local.pem",
      "key_path": "/opt/dstack-panel/docker/ssl/myapp.local-key.pem",
      "exists": true
    }
  ]
}
```

---

### `POST /api/ssl/local`

Generate a locally-trusted certificate using **mkcert**.

**Request Body:**
```json
{
  "domain": "myapp.local"
}
```

**Response:**
```json
{
  "success": true,
  "domain": "myapp.local",
  "cert_path": "/opt/dstack-panel/docker/ssl/myapp.local.pem",
  "key_path": "/opt/dstack-panel/docker/ssl/myapp.local-key.pem",
  "message": "Certificate created for myapp.local via mkcert",
  "vhost_enabled": true
}
```

**Example:**
```bash
curl -X POST https://panel.chadadigital.com/api/ssl/local \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local"}'
```

---

### `POST /api/ssl/letsencrypt`

Request a Let's Encrypt certificate.

**Request Body:**
```json
{
  "domain": "myapp.example.com",
  "email": "admin@example.com",
  "mode": "standalone",
  "webroot_path": "/var/www/html"
}
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `domain` | Yes | string | — | Public domain name |
| `email` | Yes | string | — | Email for Let's Encrypt registration |
| `mode` | No | string | `standalone` | `standalone` or `webroot` |
| `webroot_path` | No* | string | — | Required if `mode=webroot` |

**Response:**
```json
{
  "success": true,
  "domain": "myapp.example.com",
  "cert_path": "/opt/dstack-panel/docker/ssl/myapp.example.com.pem",
  "key_path": "/opt/dstack-panel/docker/ssl/myapp.example.com-key.pem",
  "message": "Certificate created via Let's Encrypt",
  "vhost_enabled": true
}
```

---

## Logs

### `GET /api/logs/{service}`

Get recent log lines for a Docker service.

| Parameter | Type | Values |
|-----------|------|--------|
| `service` | string | `nginx`, `php`, `mysql`, `redis`, `phpmyadmin`, `all` |

**Query Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `lines` | int | `50` | Number of trailing lines (1–5000) |

**Response:**
```json
{
  "success": true,
  "service": "nginx",
  "lines": [
    "nginx-1  | 192.168.1.1 - - [18/Jul/2026:12:00:00 +0000] \"GET / HTTP/1.1\" 200"
  ],
  "truncated": false
}
```

---

### `GET /api/logs/{service}/stream`

Stream live logs (text/plain).

```bash
curl -N https://panel.chadadigital.com/api/logs/nginx/stream
```

---

## Backup & Restore

### `GET /api/backups`

List all available backups.

**Response:**
```json
{
  "success": true,
  "data": [
    {
      "id": "20260718_120000",
      "timestamp": "20260718_120000",
      "description": "Pre-deployment backup",
      "database": "all",
      "size_bytes": 2048576
    }
  ]
}
```

---

### `POST /api/backup`

Create a database backup.

**Request Body:**
```json
{
  "database": "all",
  "description": "Pre-deployment backup"
}
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `database` | No | string | `all` | Database name or `all` |
| `description` | No | string | `""` | Free-text description |

**Response:**
```json
{
  "success": true,
  "backup_id": "20260718_120000",
  "path": "/opt/dstack-panel/backups/20260718_120000",
  "files": ["all.sql.gz"],
  "message": "Backup '20260718_120000' created."
}
```

---

### `POST /api/restore`

Restore a database backup.

**Request Body:**
```json
{
  "backup_id": "20260718_120000",
  "database": "devstack"
}
```

**Response:**
```json
{
  "success": true,
  "message": "Restore from '20260718_120000' completed."
}
```

---

## Server-Sent Events (SSE)

### `GET /api/events`

Real-time event stream for the panel UI. Uses `EventSource` in `resources/js/app.js`.

**Response:** `text/event-stream`

```
event: log
data: {"service":"nginx","message":"..."}

event: service
data: {"name":"nginx","state":"running"}

event: health
data: {"status":"ok"}
```

---

## RDS SSH Tunnel

### `GET /api/rds/tunnel/status`

Get current tunnel status.

**Response:**
```json
{
  "connected": true,
  "local_port": 3307,
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306,
  "ec2_host": "203.0.113.10",
  "ec2_user": "ubuntu"
}
```

---

### `POST /api/rds/tunnel/start`

Start an SSH tunnel to RDS via EC2 bastion.

**Request Body:**
```json
{
  "ec2_host": "203.0.113.10",
  "ec2_user": "ubuntu",
  "ec2_key_path": "/home/user/.ssh/devstack-ec2",
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306,
  "local_port": 3307
}
```

**Response:**
```json
{
  "success": true,
  "message": "Tunnel established: 127.0.0.1:3307 -> my-rds...:3306 via 203.0.113.10",
  "local_port": 3307
}
```

---

### `POST /api/rds/tunnel/stop`

Stop the active RDS tunnel.

**Response:**
```json
{
  "success": true,
  "message": "Tunnel disconnected"
}
```

---

## HTTP Status Codes

| Code | Meaning |
|------|---------|
| `200` | Success |
| `401` | Unauthenticated |
| `403` | Forbidden |
| `404` | Not found (vhost, backup, etc.) |
| `422` | Validation error |
| `500` | Internal server error |

---

## CLI Usage Examples

```bash
# Health
curl -s https://panel.chadadigital.com/api/health | jq

# Services
curl -s https://panel.chadadigital.com/api/services | jq
curl -X POST https://panel.chadadigital.com/api/services/nginx/restart

# VHosts
curl -s https://panel.chadadigital.com/api/vhosts | jq
curl -X POST https://panel.chadadigital.com/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local", "framework": "laravel"}'

# SSL
curl -X POST https://panel.chadadigital.com/api/ssl/local \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local"}'

# Logs
curl -s "https://panel.chadadigital.com/api/logs/nginx?lines=100" | jq
curl -N https://panel.chadadigital.com/api/logs/nginx/stream

# Backups
curl -s https://panel.chadadigital.com/api/backups | jq
curl -X POST https://panel.chadadigital.com/api/backup \
  -H "Content-Type: application/json" \
  -d '{"database": "all", "description": "Pre-deploy"}'
curl -X POST https://panel.chadadigital.com/api/restore \
  -H "Content-Type: application/json" \
  -d '{"backup_id": "20260718_120000"}'

# RDS Tunnel
curl -X POST https://panel.chadadigital.com/api/rds/tunnel/start \
  -H "Content-Type: application/json" \
  -d '{"ec2_host":"203.0.113.10","ec2_user":"ubuntu","ec2_key_path":"~/.ssh/ec2","rds_host":"my-rds.abc123.us-east-1.rds.amazonaws.com"}'
```
