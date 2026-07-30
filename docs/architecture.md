# Architecture Overview

This document explains the DStack Panel project structure, runtime components, and the deployment model.

---

## High-Level Architecture

DStack Panel is a **Laravel 12** single-page application (SPA) that manages Docker stacks via the host Docker daemon. The panel itself is served directly by nginx + PHP-FPM on the host.

```
┌──────────────────────────────────────────────────────────────┐
│                        EC2 Host                              │
│                                                              │
│  ┌────────────────┐         ┌──────────────────────────┐    │
│  │   nginx         │         │   Docker Compose Stack   │    │
│  │  (host)         │    ──►  │                          │    │
│  │                 │ proxy   │  nginx, php-fpm, mysql,  │    │
│  │  /run/php/      │         │  redis, phpmyadmin       │    │
│  │  php8.2-fpm-    │         │                          │    │
│  │  dstack.sock    │         └──────────────────────────┘    │
│  └───────┬─────────┘                                         │
│          │                                                     │
│  ┌───────▼──────────────────────────────────────────────┐   │
│  │         Laravel 12 Panel App (served via FPM)         │   │
│  │                                                        │   │
│  │  app/Services/            │                           │   │
│  │  routes/ (web.php, api)   │                           │   │
│  │  config/ (dstack.php)     │                           │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Panel SPA connects via:                                    │
│  - REST API (JSON)                                          │
│  - SSE (EventSource) at /api/events                         │
└──────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Host Nginx + PHP-FPM

- nginx configuration: `nginx/chadadigital.com.conf`
- PHP-FPM pool: `/etc/php/8.2/fpm/pool.d/dstack.conf`
- Serves the Laravel panel directly via PHP-FPM socket (`/run/php/php8.2-fpm-dstack.sock`)
- Proxies external project requests to the Docker Compose stack (separate nginx in Docker)
- Handles WebSocket upgrade headers for SSE at `/api/events`
- Static assets (`/assets/`) served directly by nginx, bypassing PHP

### 2. Docker Compose Stack (Projects)

- File: `docker/docker-compose.yml`
- Services: nginx, php-fpm, mysql, redis, phpmyadmin
- Manages the host project vhosts in `docker/vhosts/`
- Projects served from `PROJECTS_ROOT` (e.g., `/opt/dstack-panel/projects/`)

### 3. Laravel Panel Application

- **Framework**: Laravel 12
- **Frontend**: SPA built with Bun + Vite (resources/js/app.js)
- **Backend**: Eloquent ORM with SQLite (local) / MySQL (production)
- **Realtime**: Server-Sent Events via `EventController@stream`

---

## Directory Structure

### Application Code

```
app/
├── Console/Commands/
│   ├── DStackUpdate.php          # Self-update deployment
│   ├── DStackBootstrap.php       # First-run environment bootstrap
│   ├── DStackHealth.php          # Diagnostic health check
│   ├── DStackSetup.php           # First-run wizard
│   └── DstackVersionSync.php     # Sync version from git tags
├── Http/
│   ├── Controllers/
│   │   ├── AuthController.php    # Login/logout
│   │   ├── DashboardController.php
│   │   ├── ServiceController.php # Docker service control
│   │   ├── BackupController.php  # Backup/restore
│   │   ├── VhostController.php   # Virtual host CRUD
│   │   ├── SslController.php     # SSL certificate management
│   │   ├── LogController.php     # Docker log aggregation
│   │   ├── EventController.php   # SSE event stream
│   │   ├── HealthController.php  # Health check
│   │   └── RdsTunnelController.php
│   ├── Requests/                 # Form request validation
│   └── Middleware/                # HTTP middleware
├── Models/
│   └── User.php                   # User model
└── Services/
    ├── DockerComposeService.php   # docker compose interactions
    ├── SslService.php             # mkcert / Let's Encrypt
    ├── BackupService.php          # mysqldump / tar archives
    ├── VhostService.php           # nginx vhost generation
    ├── LogService.php             # Docker log tailing
    └── RdsTunnelService.php       # SSH tunnel via Paramiko
```

### Configuration

```
config/
├── app.php           # Laravel application config
├── auth.php          # Authentication driver
├── cache.php         # Cache configuration
├── database.php      # Database connections
├── dstack.php        # DStack-specific paths and constants
├── logging.php       # Log channels
├── mail.php          # Mail driver
├── queue.php         # Queue connection
├── services.php      # Third-party service credentials
└── session.php       # Session driver
```

### Frontend

```
resources/
├── js/app.js           # Main SPA entry point (SPA with SSE)
├── css/                # Stylesheets
└── views/
    └── panel/
        └── index.blade.php  # SPA shell (locked, JS/CSS only)
```

### Tests

```
tests/
├── Feature/
│   ├── DashboardControllerTest.php
│   ├── ServiceControllerTest.php
│   ├── BackupControllerTest.php
│   ├── VhostControllerTest.php
│   ├── SslControllerTest.php
│   ├── LogControllerTest.php
│   └── ...
└── Unit/
    ├── DockerComposeServiceTest.php
    ├── SslServiceTest.php
    ├── BackupServiceTest.php
    └── ...
```

---

## Deployment Flow

```
User Request
    │
    ▼
nginx (ports 80/443)
    │
    ▼
FastCGI → PHP-FPM socket (/run/php/php8.2-fpm-dstack.sock)
    │
    ▼
Laravel application (routes/web.php, routes/api.php)
    │
    ▼
Response (HTML, JSON, or text/event-stream for SSE)
```

### Deploy Sequence

1. CI builds assets (`bun run prod`) and packages the release tarball
2. Rsyncs code to `/opt/dstack-panel`
3. Runs migrations (`php artisan migrate --force`)
4. Runs Laravel optimization (`php artisan config:cache`, `route:cache`, etc.)
5. Restarts PHP-FPM to pick up code changes
6. Health checks `/up` and `/api/health`
7. Reloads nginx if config changed

### Rollback

If step 6 fails, the pipeline exits non-zero. The previous code version remains running since PHP-FPM reads files on each request. Rollback is achieved by rsyncing the previous release tarball back to `/opt/dstack-panel` and restarting PHP-FPM.

---

## Data Flow

### Docker Service Control

```
Browser/API Client
    → POST /api/services/nginx/restart
    → ServiceController::action()
    → DockerComposeService::run(['restart', 'nginx'])
    → Docker Socket (/var/run/docker.sock)
    → Docker daemon restarts container
```

### Virtual Host Creation

```
Browser/API Client
    → POST /api/vhosts {domain: "myapp.local"}
    → VhostController::store()
    → VhostService::create($domain, $framework)
    → Renders docker/vhosts/chadadigital.local.conf template
    → Writes docker/vhosts/myapp.local.conf
    → docker compose exec nginx nginx -s reload
```

### SSE Event Stream

```
Browser (EventSource)
    → GET /api/events
    → EventController::stream()
    → Reads storage/logs/*.log or Docker events
    → Returns text/event-stream
    → Browser updates panel UI in real time
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Laravel 12 instead of Flask | PHP 8.2 ecosystem, Eloquent ORM, built-in auth, routing, testing |
| Single PHP-FPM + nginx instance | Simpler than blue-green, no port-based upstream needed |
| systemd template (`dstack-panel@.service`) | Type=oneshot deployment trigger, runs migration and optimization |
| nginx serves PHP directly via FPM socket | No reverse proxy to artisan serve, better performance |
| SQLite locally, MySQL in production | Zero-config local dev, scalable production |
| Bun + Vite frontend | Fast builds, SPA support, asset versioning |
| SSE over polling | Efficient real-time log/event streaming |
| `/etc/nginx/sites-available/` on host | Clean separation from Docker-managed vhosts |
| PHP-FPM dynamic PM (max_children=6) | Tuned for t3.small with 2 GB RAM |
| www-data for file ownership | Least-privilege for PHP-FPM process |
