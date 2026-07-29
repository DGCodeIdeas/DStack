# Architecture Overview

This document explains the DStack Panel project structure, runtime components, and the blue-green deployment model.

---

## High-Level Architecture

DStack Panel is a **Laravel 12** single-page application (SPA) that manages Docker stacks via the host Docker daemon. The panel itself runs as two blue-green PHP built-in server instances behind an nginx reverse proxy.

```
┌──────────────────────────────────────────────────────────────┐
│                        EC2 Host                              │
│                                                              │
│  ┌────────────────┐         ┌──────────────────────────┐    │
│  │   nginx        │         │   Docker Compose Stack   │    │
│  │  (host)        │         │                          │    │
│  │                │◄───────►│  nginx, php-fpm, mysql,  │    │
│  │ panel_backend  │ proxy   │  redis, phpmyadmin       │    │
│  │ upstream       │         │                          │    │
│  │ 127.0.0.1:5000 │         └──────────────────────────┘    │
│  │ 127.0.0.1:5001 │                                         │
│  └───────┬────────┘                                         │
│          │                                                   │
│  ┌───────▼────────┐     ┌──────────────────────────┐       │
│  │ dstack-panel@  │     │   Laravel 12 Panel App    │       │
│  │ green (5000)   │     │                          │       │
│  └────────────────┘     │  app/Services/            │       │
│  ┌────────────────┐     │  - DockerComposeService   │       │
│  │ dstack-panel@  │     │  - SslService             │       │
│  │ blue (5001)    │     │  - BackupService          │       │
│  └────────────────┘     │  - VhostService           │       │
│                         │  - LogService             │       │
│                         │  - RdsTunnelService       │       │
│                         │                          │       │
│                         │  routes/                  │       │
│                         │  - web.php (SPA fallback) │       │
│                         │  - api.php (REST API)     │       │
│                         │  - console.php (Artisan)  │       │
│                         └──────────────────────────┘       │
│                                                              │
│  Panel SPA connects via:                                    │
│  - REST API (JSON)                                          │
│  - SSE (EventSource) at /api/events                         │
└──────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Host Nginx

- Located at `docker/nginx.conf` and `nginx/chadadigital.com.conf`
- Defines `upstream panel_backend { 127.0.0.1:5000; 127.0.0.1:5001; }`
- Proxies `panel.chadadigital.com` to the upstream
- Handles WebSocket upgrade headers for SSE

### 2. Blue-Green Systemd Instances

- Template: `systemd/dstack-panel@.service`
- Two instances: `dstack-panel@green` (port 5000) and `dstack-panel@blue` (port 5001)
- Each reads from its own env file: `.env.green` / `.env.blue`
- `EnvironmentFile=-/opt/dstack-panel/.env.%i` provides instance-specific config
- Active instance tracked in `/opt/dstack-panel/.active_instance`

### 3. Docker Compose Stack

- File: `docker/docker-compose.yml`
- Services: nginx, php-fpm, mysql, redis, phpmyadmin
- Manages the host project vhosts in `docker/vhosts/`
- Projects served from `PROJECTS_ROOT` (e.g., `/opt/dstack-panel/projects/`)

### 4. Laravel Panel Application

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
│   ├── DStackUpdate.php          # Self-update (blue-green)
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

## Blue-Green Runtime Flow

```
User Request
    │
    ▼
nginx listens on 80/443
    │
    ▼
proxy_pass → panel_backend upstream
    │
    ├──────────────────────┐
    │                      │
    ▼                      ▼
127.0.0.1:5000      127.0.0.1:5001
dstack-panel@         dstack-panel@
green                 blue
(active)              (idle)
    │                      │
    │◄──── nginx reload ───┘
    │   (switches upstream)
    ▼
Response
```

### Deploy Sequence

1. CI reads `.active_instance` (e.g., `green`)
2. Computes next color (`blue`)
3. Rsyncs code to `/opt/dstack-panel`
4. Starts `dstack-panel@blue` (port 5001)
5. Runs migrations
6. Health checks `/up` and `/api/health`
7. Reloads nginx — upstream now points to `5001` first
8. Stops `dstack-panel@green`
9. Writes `blue` to `.active_instance`

### Rollback

If step 6 fails, the pipeline exits non-zero. The old instance (`green`) remains running. nginx continues serving it. No manual intervention needed — the next deploy retries.

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
| Blue-green instead of rolling | Single EC2 host, zero downtime, instant rollback |
| systemd template (`dstack-panel@.service`) | Runs two instances on different ports |
| nginx upstream proxy | Host-level routing without load balancer |
| SQLite locally, MySQL in production | Zero-config local dev, scalable production |
| Bun + Vite frontend | Fast builds, SPA support, asset versioning |
| SSE over polling | Efficient real-time log/event streaming |
| `/etc/nginx/sites-available/` on host | Clean separation from Docker-managed vhosts |
| `.active_instance` file | Simple state tracking without database |
