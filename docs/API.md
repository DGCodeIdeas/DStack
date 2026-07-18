# DStack API Reference

Complete REST API documentation for the DStack Flask backend (`server/app.py`). All endpoints are served at `http://localhost:5000` by default.

---

## Base URL

```
http://localhost:5000/api
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
  "error_code": "OPTIONAL_CODE"
}
```

---

## Health Check

### `GET /api/health`

Liveness probe. Returns `200 OK` if the Flask server is running.

**Response:**
```json
{
  "status": "ok"
}
```

**Example:**
```bash
curl http://localhost:5000/api/health
```

---

## Services Management

### `GET /api/services`

Get status of all Docker Compose services.

**Response:**
```json
{
  "nginx": {
    "status": "Up 5 minutes (healthy)",
    "state": "running",
    "health": "healthy"
  },
  "php": {
    "status": "Up 5 minutes",
    "state": "running",
    "health": null
  },
  "mysql": {
    "status": "Up 5 minutes (healthy)",
    "state": "running",
    "health": "healthy"
  },
  "phpmyadmin": {
    "status": "Up 5 minutes",
    "state": "running",
    "health": null
  },
  "redis": {
    "status": "Up 5 minutes (healthy)",
    "state": "running",
    "health": "healthy"
  }
}
```

**Example:**
```bash
curl http://localhost:5000/api/services
```

---

### `POST /api/services/<service>/<action>`

Control a service: `start`, `stop`, or `restart`.

**Path Parameters:**
| Parameter | Type | Values |
|-----------|------|--------|
| `service` | string | `nginx`, `php`, `mysql`, `phpmyadmin`, `redis`, `all` |
| `action` | string | `start`, `stop`, `restart` |

**Response:**
```json
{
  "success": true,
  "message": "Service nginx started",
  "status": { ... }
}
```

**Examples:**
```bash
# Start nginx
curl -X POST http://localhost:5000/api/services/nginx/start

# Stop all services
curl -X POST http://localhost:5000/api/services/all/stop

# Restart MySQL
curl -X POST http://localhost:5000/api/services/mysql/restart
```

---

## Virtual Hosts

### `GET /api/vhosts`

List all configured virtual hosts.

**Response:**
```json
[
  {
    "domain": "testapp.local",
    "config_path": "/home/user/DStack/docker/vhosts/testapp.local.conf",
    "root": "/home/user/DStack/projects/testapp.local",
    "framework": "php"
  },
  {
    "domain": "myapp.local",
    "config_path": "/home/user/DStack/docker/vhosts/myapp.local.conf",
    "root": "/home/user/DStack/projects/myapp.local/public",
    "framework": "laravel"
  }
]
```

**Example:**
```bash
curl http://localhost:5000/api/vhosts
```

---

### `POST /api/vhosts`

Create a new virtual host.

**Request Body:**
```json
{
  "domain": "myapp.local",
  "framework": "laravel",
  "root": "/home/user/DStack/projects/myapp.local/public"
}
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `domain` | Yes | string | — | Valid hostname (e.g., `myapp.local`) |
| `framework` | No | string | `php` | `php`, `laravel`, `symfony`, `wordpress`, `static` |
| `root` | No | string | Auto | Host-side web root path |

**Response (200):**
```json
{
  "success": true,
  "domain": "myapp.local",
  "root": "/home/user/DStack/projects/myapp.local/public",
  "config_path": "/home/user/DStack/docker/vhosts/myapp.local.conf",
  "warnings": []
}
```

**Response (400 - invalid domain):**
```json
{
  "success": false,
  "message": "domain must be a valid hostname (e.g. 'testapp.local' or 'api.example.com')",
  "domain": "invalid..domain"
}
```

**Examples:**
```bash
# Create PHP vhost
curl -X POST http://localhost:5000/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local", "framework": "php"}'

# Create Laravel vhost with custom root
curl -X POST http://localhost:5000/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "laravel.local", "framework": "laravel", "root": "/var/www/projects/laravel.local/public"}'
```

---

### `DELETE /api/vhosts/<domain>`

Delete a virtual host.

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `domain` | string | Domain to delete |

**Query Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `remove_files` | boolean | `false` | Also delete the project directory |

**Response (200):**
```json
{
  "success": true,
  "domain": "myapp.local",
  "missing": false,
  "removed_config": "/home/user/DStack/docker/vhosts/myapp.local.conf",
  "removed_files": "/home/user/DStack/projects/myapp.local",
  "warnings": []
}
```

**Response (404 - not found):**
```json
{
  "success": false,
  "domain": "nonexistent.local",
  "missing": true,
  "warnings": ["No vhost config found at /home/user/DStack/docker/vhosts/nonexistent.local.conf"]
}
```

**Examples:**
```bash
# Delete vhost only
curl -X DELETE http://localhost:5000/api/vhosts/myapp.local

# Delete vhost and project files
curl -X DELETE "http://localhost:5000/api/vhosts/myapp.local?remove_files=true"
```

---

## SSL Certificates

### `GET /api/ssl` or `GET /api/ssl/certs`

List all certificates in the SSL directory.

**Response:**
```json
[
  {
    "domain": "myapp.local",
    "cert_path": "/home/user/DStack/docker/ssl/myapp.local.pem",
    "key_path": "/home/user/DStack/docker/ssl/myapp.local-key.pem",
    "exists": true
  }
]
```

**Example:**
```bash
curl http://localhost:5000/api/ssl
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

**Response (200):**
```json
{
  "success": true,
  "domain": "myapp.local",
  "cert_path": "/home/user/DStack/docker/ssl/myapp.local.pem",
  "key_path": "/home/user/DStack/docker/ssl/myapp.local-key.pem",
  "message": "Certificate created for myapp.local via mkcert",
  "vhost_enabled": true,
  "warnings": []
}
```

**Response (400 - mkcert not installed):**
```json
{
  "success": false,
  "domain": "myapp.local",
  "message": "mkcert not installed. Install via 'brew install mkcert' / 'sudo apt install mkcert' then run 'mkcert -install'"
}
```

**Example:**
```bash
curl -X POST http://localhost:5000/api/ssl/local \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.local"}'
```

---

### `POST /api/ssl/letsencrypt`

Request a Let's Encrypt certificate via **certbot**.

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

**Response (200):**
```json
{
  "success": true,
  "domain": "myapp.example.com",
  "cert_path": "/home/user/DStack/docker/ssl/myapp.example.com.pem",
  "key_path": "/home/user/DStack/docker/ssl/myapp.example.com-key.pem",
  "message": "Certificate created for myapp.example.com via Let's Encrypt",
  "vhost_enabled": true,
  "warnings": []
}
```

**Example:**
```bash
# Standalone mode (stops nginx temporarily on port 80)
curl -X POST http://localhost:5000/api/ssl/letsencrypt \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.example.com", "email": "admin@example.com"}'

# Webroot mode (nginx keeps running)
curl -X POST http://localhost:5000/api/ssl/letsencrypt \
  -H "Content-Type: application/json" \
  -d '{"domain": "myapp.example.com", "email": "admin@example.com", "mode": "webroot", "webroot_path": "/var/www/html"}'
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
  "ec2_user": "ec2-user",
  "transport_active": true
}
```

**Example:**
```bash
curl http://localhost:5000/api/rds/tunnel/status
```

---

### `POST /api/rds/tunnel/start`

Start an SSH tunnel to RDS via EC2 bastion.

**Request Body:**
```json
{
  "ec2_host": "203.0.113.10",
  "ec2_user": "ec2-user",
  "ec2_key_path": "/home/user/.ssh/devstack-ec2",
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306,
  "local_port": 3307
}
```

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `ec2_host` | Yes | string | — | EC2 public IP or DNS |
| `ec2_user` | Yes | string | — | SSH user (e.g., `ec2-user`, `ubuntu`) |
| `ec2_key_path` | Yes | string | — | Path to **private** SSH key |
| `rds_host` | Yes | string | — | RDS endpoint |
| `rds_port` | No | int | `3306` | RDS port |
| `local_port` | No | int | `3307` | Local port to bind |

**Response (200):**
```json
{
  "success": true,
  "message": "Tunnel established: 127.0.0.1:3307 -> my-rds.abc123.us-east-1.rds.amazonaws.com:3306 via 203.0.113.10",
  "local_port": 3307,
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306
}
```

**Response (400 - key not found):**
```json
{
  "success": false,
  "message": "ec2_key_path does not exist: /home/user/.ssh/missing-key",
  "local_port": 3307,
  "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
  "rds_port": 3306
}
```

**Example:**
```bash
curl -X POST http://localhost:5000/api/rds/tunnel/start \
  -H "Content-Type: application/json" \
  -d '{
    "ec2_host": "203.0.113.10",
    "ec2_user": "ec2-user",
    "ec2_key_path": "/home/user/.ssh/devstack-ec2",
    "rds_host": "my-rds.abc123.us-east-1.rds.amazonaws.com",
    "rds_port": 3306,
    "local_port": 3307
  }'
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

**Example:**
```bash
curl -X POST http://localhost:5000/api/rds/tunnel/stop
```

---

## Logs Aggregation

### `GET /api/logs/<service>`

Get recent log lines for a service.

**Path Parameters:**
| Parameter | Type | Values |
|-----------|------|--------|
| `service` | string | `nginx`, `php`, `mysql`, `redis`, `phpmyadmin`, `all` |

**Query Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `lines` | int | `50` | Number of trailing lines (1–5000) |
| `follow` | boolean | `false` | If true, streams live logs (see below) |

**Response:**
```json
{
  "service": "nginx",
  "lines": [
    "nginx-1  | 192.168.1.1 - - [18/Jul/2026:12:00:00 +0000] \"GET / HTTP/1.1\" 200",
    "nginx-1  | 192.168.1.1 - - [18/Jul/2026:12:00:01 +0000] \"GET /favicon.ico HTTP/1.1\" 404"
  ],
  "raw": "nginx-1  | 192.168.1.1 - - [...]\nnginx-1  | 192.168.1.1 - - [...]",
  "success": true,
  "message": "OK",
  "truncated": false,
  "entries": [
    {"raw": "...", "service": "nginx", "message": "..."},
    {"raw": "...", "service": "nginx", "message": "..."}
  ]
}
```

**Examples:**
```bash
# Last 50 lines of nginx
curl http://localhost:5000/api/logs/nginx

# Last 100 lines of all services
curl "http://localhost:5000/api/logs/all?lines=100"

# Last 20 lines of MySQL
curl "http://localhost:5000/api/logs/mysql?lines=20"
```

---

### `GET /api/logs/<service>/stream`

Stream live logs (Server-Sent Events / plain text stream).

**Path Parameters:**
| Parameter | Type | Values |
|-----------|------|--------|
| `service` | string | `nginx`, `php`, `mysql`, `redis`, `phpmyadmin`, `all` |

**Response:** `text/plain` stream, one log line per newline.

**Example:**
```bash
# Stream nginx logs (Ctrl+C to stop)
curl -N http://localhost:5000/api/logs/nginx/stream

# Stream all services
curl -N http://localhost:5000/api/logs/all/stream
```

> **Note**: Use `-N` (no-buffer) with curl for real-time streaming.

---

## Backup & Restore

### `GET /api/backups`

List all available backups (newest first).

**Response:**
```json
[
  {
    "id": "20260718_120000",
    "timestamp": "20260718_120000",
    "description": "Pre-deployment backup",
    "database": "all",
    "size_bytes": 2048576,
    "files": ["all.sql.gz"]
  },
  {
    "id": "20260717_180000",
    "timestamp": "20260717_180000",
    "description": "Scheduled backup",
    "database": "devstack",
    "size_bytes": 1024000,
    "files": ["devstack.sql.gz"]
  }
]
```

**Example:**
```bash
curl http://localhost:5000/api/backups
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
| `database` | No | string | `all` | Database name or `all` for all databases |
| `description` | No | string | `""` | Free-text description for manifest |

**Response (200):**
```json
{
  "success": true,
  "backup_id": "20260718_120000",
  "path": "/home/user/DStack/backups/20260718_120000",
  "files": ["all.sql.gz"],
  "message": "Backup '20260718_120000' created."
}
```

**Response (400 - invalid database name):**
```json
{
  "success": false,
  "message": "Invalid database name: 'my-db'. Use 'all' or a name matching [A-Za-z0-9_]+."
}
```

**Examples:**
```bash
# Backup all databases
curl -X POST http://localhost:5000/api/backup \
  -H "Content-Type: application/json" \
  -d '{"description": "Full backup before migration"}'

# Backup specific database
curl -X POST http://localhost:5000/api/backup \
  -H "Content-Type: application/json" \
  -d '{"database": "myapp", "description": "MyApp schema only"}'
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

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `backup_id` | Yes | string | Timestamp directory name (e.g., `20260718_120000`) |
| `database` | No | string | Target database (optional; restores to original if omitted) |

**Response (200):**
```json
{
  "success": true,
  "message": "Restore from '20260718_120000' completed."
}
```

**Response (404 - backup not found):**
```json
{
  "success": false,
  "message": "Backup not found: 20260718_120000",
  "missing": true
}
```

**Examples:**
```bash
# Restore to original database(s)
curl -X POST http://localhost:5000/api/restore \
  -H "Content-Type: application/json" \
  -d '{"backup_id": "20260718_120000"}'

# Restore to a different database
curl -X POST http://localhost:5000/api/restore \
  -H "Content-Type: application/json" \
  -d '{"backup_id": "20260718_120000", "database": "myapp_restored"}'
```

---

## Error Codes Reference

| HTTP Status | Meaning |
|-------------|---------|
| `200` | Success |
| `400` | Bad request (invalid input, missing fields) |
| `404` | Not found (vhost, backup, etc.) |
| `500` | Internal server error (Docker daemon, subprocess failure) |

---

## Rate Limiting

No rate limiting is currently implemented. For production deployments behind a reverse proxy, configure rate limiting at the proxy layer (nginx, Traefik, etc.).

---

## Authentication

No authentication is built into the API. For production use:
- Deploy behind a VPN / SSH tunnel
- Add an auth proxy (oauth2-proxy, Authelia, etc.)
- Restrict via firewall/security groups

---

## WebSocket / Streaming Endpoints

| Endpoint | Protocol | Description |
|----------|----------|-------------|
| `GET /api/logs/<service>/stream` | HTTP streaming | Live log tail (`text/plain`) |

---

## CLI Usage Examples

### Using `httpie` (recommended for readability)
```bash
# Health
http GET :5000/api/health

# Services
http GET :5000/api/services
http POST :5000/api/services/nginx/restart

# VHosts
http GET :5000/api/vhosts
http POST :5000/api/vhosts domain=myapp.local framework=laravel
http DELETE :5000/api/vhosts/myapp.local

# SSL
http POST :5000/api/ssl/local domain=myapp.local
http POST :5000/api/ssl/letsencrypt domain=myapp.example.com email=admin@example.com

# RDS Tunnel
http POST :5000/api/rds/tunnel/start \
  ec2_host=203.0.113.10 \
  ec2_user=ec2-user \
  ec2_key_path=~/.ssh/devstack-ec2 \
  rds_host=my-rds.abc123.us-east-1.rds.amazonaws.com

# Logs
http GET :5000/api/logs/nginx lines==100
http --stream GET :5000/api/logs/nginx/stream

# Backups
http GET :5000/api/backups
http POST :5000/api/backup database=all description="Pre-deploy"
http POST :5000/api/restore backup_id=20260718_120000
```

---

## OpenAPI / Swagger

An OpenAPI 3.0 specification is not yet bundled. To generate one, consider using `flasgger` or `apispec` with the Flask app.