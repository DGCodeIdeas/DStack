# DStack — Local Development Stack Manager

**DStack** is a lightweight, Docker-based local development stack manager for PHP/Laravel applications. It provides a Laravel-based REST API and web dashboard to manage Docker services, virtual hosts, SSL certificates, database backups, RDS tunnels, and logs — all from a single interface.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| **Service Management** | Start/stop/restart Docker Compose services (nginx, php-fpm, mysql, redis, phpmyadmin) via API or UI |
| **Virtual Hosts** | Create/delete nginx vhosts for PHP, Laravel, Symfony, WordPress, or static sites |
| **SSL Certificates** | Generate locally-trusted certs with **mkcert** or request **Let's Encrypt** certs via API/UI |
| **RDS SSH Tunnel** | Secure SSH tunnel from localhost → EC2 bastion → Amazon RDS (ssh binary + PID file) |
| **Log Aggregation** | Tail/follow logs from nginx, php-fpm, mysql, redis, phpmyadmin via API or streaming UI |
| **Backup & Restore** | Dump/restore MySQL databases (all or single DB) with timestamped manifests |
| **Web Dashboard** | Single-page UI (vanilla JS) served by Laravel at `http://localhost:5000` |
| **CLI Commands** | Artisan commands (`php artisan dstack:*`) for bootstrap, setup, update, and health checks |
| **One-Command Install** | `./cloud/install-local.sh` — clones repo, builds images, starts stack, opens dashboard |
| **EC2 Deployment** | `cloud/provision-ec2.sh` provisions a new EC2 instance or bootstraps an existing one (`--existing`) |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DStack Architecture                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐     ┌────────────────────────────────────────────────┐   │
│  │   Browser    │────▶│              Laravel API (port 5000)            │   │
│  │  (Dashboard) │     │  ┌──────────────────────────────────────────┐  │   │
│  └──────────────┘     │  │           ServiceManager                  │  │   │
│                       │  │  • docker compose ps/up/down/restart       │  │   │
│  ┌──────────────┐     │  │  • Health checks (nginx, php, mysql, etc) │  │   │
│  │   Terminal   │────▶│  ┌──────────────────────────────────────────┐  │   │
│  │   (CLI)      │     │  │           VirtualHostManager              │  │   │
│                       │  │  • Create/delete nginx vhost configs      │  │   │
│  ┌──────────────┐     │  │  • Frameworks: php, laravel, symfony,     │  │   │
│  │   curl /     │────▶│  │    wordpress, static                      │  │   │
│  │   HTTPie     │     │  └──────────────────────────────────────────┘  │   │
│  └──────────────┘     │  ┌──────────────────────────────────────────┐  │   │
│                       │  │           SSLManager                      │  │   │
│                       │  │  • mkcert (local CA)                      │  │   │
│                       │  │  • Let's Encrypt (standalone/webroot)     │  │   │
│                       │  └──────────────────────────────────────────┘  │   │
│                       │  ┌──────────────────────────────────────────┐  │   │
│                       │  │           RdsTunnelService (ssh binary)     │  │   │
│                       │  │  • SSH tunnel: localhost → EC2 → RDS      │  │   │
│                       │  │  • Auto-reconnect with backoff            │  │   │
│                       │  └──────────────────────────────────────────┘  │   │
│                       │  ┌──────────────────────────────────────────┐  │   │
│                       │  │           LogAggregator                   │  │   │
│                       │  │  • docker compose logs --tail N           │  │   │
│                       │  │  • Streaming via ?follow=1                │  │   │
│                       │  └──────────────────────────────────────────┘  │   │
│                       │  ┌──────────────────────────────────────────┐  │   │
│                       │  │           BackupManager                   │  │   │
│                       │  │  • mysqldump (all or single DB)           │  │   │
│                       │  │  • Timestamped dirs + manifest.json       │  │   │
│                       │  │  • Restore with optional target DB rename │  │   │
│                       │  └──────────────────────────────────────────┘  │   │
│                       └────────────────────────────────────────────────┘   │
│                                      │                                      │
│                                      ▼                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        Docker Compose Stack                          │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐    │  │
│  │  │  nginx  │  │   php   │  │  mysql  │  │  redis  │  │ phpmyad │    │  │
│  │  │  :80    │◀─│  :9000  │  │  :3306  │  │  :6379  │  │  :8080  │    │  │
│  │  │  :443   │  │  fpm    │  │         │  │         │  │  admin  │    │  │
│  │  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘    │  │
│  │       │            │            │            │            │          │  │
│  │       └────────────┴────────────┴────────────┴────────────┘          │  │
│  │                    │                    │                              │  │
│  │         ./projects ──────────────────────┘                              │  │
│  │         ./docker/ssl ─────────────────────────────────────────────────┘  │  │
│  │         ./docker/vhosts ────────────────────────────────────────────────┘  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start (Local)

### Prerequisites
- **Docker** + **Docker Compose v2** (`docker compose`)
- **Python 3.10+** with `venv`
- **git**
- **mkcert** (optional, for local HTTPS)

### One-Command Install
```bash
# Clone and run the installer
git clone https://github.com/dgi-dev/DStack.git
cd DStack
./cloud/install-local.sh
```

The script will:
1. ✅ Verify prerequisites (Docker, Python 3.10+, git, mkcert)
2. 📦 Build Docker images
3. 🚀 Start all services (nginx, php-fpm, mysql, redis, phpmyadmin)
4. 🌐 Create a test vhost (`testapp.local`)
5. 🌐 Start Laravel panel on `http://localhost:5000`
6. 🌐 Open dashboard in browser (if `DISPLAY` is set)

### Access Points
| Service | URL |
|---------|-----|
| **Dashboard** | http://localhost:5000 |
| **phpMyAdmin** | http://localhost:8080 |
| **Test vhost** | http://testapp.local (add `127.0.0.1 testapp.local` to `/etc/hosts`) |
| **MySQL** | `localhost:3306` (root / password from `.env`) |
| **Redis** | `localhost:6379` |

### Manual Start (if not using installer)
```bash
# 1. Copy env and set passwords
cp .env.example .env
# Edit .env with secure passwords

# 2. Build and start Docker stack
docker compose -f docker/docker-compose.yml build
docker compose -f docker/docker-compose.yml up -d

# 3. Start Laravel panel
php artisan serve --host=127.0.0.1 --port=5000
# Dashboard at http://localhost:5000
```

---

## ☁️ Quick Start (EC2 Production)

Deploy the full stack to AWS EC2 with RDS backend:

```bash
# 1. Configure
cp cloud/config.env.example cloud/config.env
vim cloud/config.env  # Fill in AWS_REGION, AWS_KEY_NAME, RDS_ENDPOINT, etc.

# 2a. Provision NEW EC2 + bootstrap stack
chmod +x cloud/provision-ec2.sh cloud/ec2-setup.sh
./cloud/provision-ec2.sh

# 2b. Or bootstrap EXISTING EC2/RDS
./cloud/provision-ec2.sh --existing
# or: ./cloud/provision-ec2.sh --existing --ip <YOUR_EC2_PUBLIC_IP>

# 3. Wait 2-3 min for bootstrap, then access:
# HTTP:  http://<PUBLIC_IP>:5000
# HTTPS: https://<YOUR_DOMAIN> (if DOMAIN + EMAIL_FOR_LETSENCRYPT set)
```

See [docs/EC2_DEPLOYMENT.md](docs/EC2_DEPLOYMENT.md) for full details.

---

## 📡 API Reference (Summary)

Base URL: `http://localhost:5000/api`

| Category | Endpoint | Method | Description |
|----------|----------|--------|-------------|
| **Health** | `/health` | GET | Liveness probe |
| **Services** | `/services` | GET | List all service statuses |
| | `/services/<name>/<action>` | POST | `action` = start\|stop\|restart |
| **VHosts** | `/vhosts` | GET | List all virtual hosts |
| | `/vhosts` | POST | Create vhost `{domain, framework?, root?}` |
| | `/vhosts/<domain>` | DELETE | Delete vhost |
| **SSL** | `/ssl` or `/ssl/certs` | GET | List certificates |
| | `/ssl/local` | POST | Create mkcert cert `{domain}` |
| | `/ssl/letsencrypt` | POST | Request LE cert `{domain, email, mode?, webroot_path?}` |
| **RDS Tunnel** | `/rds/tunnel/start` | POST | Start tunnel `{ec2_host, ec2_user, ec2_key_path, rds_host, rds_port?, local_port?}` |
| | `/rds/tunnel/stop` | POST | Stop tunnel |
| | `/rds/tunnel/status` | GET | Tunnel status |
| **Logs** | `/logs/<service>` | GET | Last N lines (`?lines=50`) |
| | `/logs/<service>` | GET | Stream live (`?follow=1`) |
| | `/logs/<service>/stream` | GET | Stream live (text/plain) |
| **Backups** | `/backup` | POST | Create backup `{database?, description?}` |
| | `/backups` | GET | List backups (newest first) |
| | `/restore` | POST | Restore backup `{backup_id, database?}` |

> Full API docs with curl examples: [docs/API.md](docs/API.md)

---

## 🖥️ Web Dashboard

Start the Laravel panel and open `http://localhost:5000`:

![Dashboard](docs/screenshots/dashboard.png)

**Sections:**
- **Services** — Start/stop/restart each Docker service, view health
- **Virtual Hosts** — Add/delete vhosts, choose framework (PHP, Laravel, Symfony, WordPress, Static)
- **SSL** — Generate mkcert or Let's Encrypt certs, view cert details
- **RDS Tunnel** — Configure and start/stop SSH tunnel to RDS
- **Logs** — Tail/follow logs for any service with auto-refresh
- **Backups** — Create, list, restore database backups

---

## ⌨️ CLI Commands

```bash
# Bootstrap the environment (Docker, PHP, migrations, APP_KEY)
php artisan dstack:bootstrap

# First-run setup (pull images, create admin, create first vhost)
php artisan dstack:setup

# Self-update (git pull, composer install, migrate, restart)
php artisan dstack:update

# Health check (Docker, port 5000, storage, SQLite, nginx)
php artisan dstack:health
```

Navigate with arrow keys, `Enter` to select, `q` to quit.

![Panel](docs/screenshots/panel.png)

---

## 📁 Project Structure

```
DStack/
├── cloud/                  # Cloud deployment scripts
│   ├── install-local.sh    # One-command local install
│   ├── provision-ec2.sh    # EC2 provisioning
│   ├── ec2-setup.sh        # EC2 bootstrap (cloud-init)
│   ├── backup-cron.sh      # Backup cron for EC2
│   └── config.env.example  # EC2 config template
├── docker/                 # Docker Compose stack
│   ├── docker-compose.yml  # Services: nginx, php, mysql, redis, phpmyadmin
│   ├── Dockerfile.nginx    # Nginx + vhost include + SSL
│   ├── Dockerfile.php      # PHP-FPM 8.2 + extensions
│   ├── nginx.conf          # Main nginx config
│   ├── nginx-vhosts.conf   # Vhost template
│   ├── php.ini             # PHP config
│   ├── mysql.cnf           # MySQL config
│   ├── ssl/                # SSL certs (mkcert/LE)
│   └── vhosts/             # Generated vhost configs
├── app/                    # Laravel application
│   ├── Http/Controllers/   # API controllers
│   ├── Http/Requests/      # Form request validation
│   ├── Services/           # Service layer (DockerCompose, Vhost, SSL, etc.)
│   ├── Providers/          # Service providers
│   └── Console/Commands/   # Artisan commands
├── config/                 # Laravel config (dstack.php, database.php)
├── database/               # Migrations and seeds
│   └── migrations/
├── resources/              # Blade views, JS, SCSS
│   ├── views/
│   ├── js/
│   └── sass/
├── routes/                 # API and web routes
├── systemd/                # systemd service file
├── init.sh                 # Installation script
├── projects/               # Project roots (mounted into containers)
│   ├── sample-app/         # Minimal Laravel-style skeleton
│   ├── demo.local/
│   └── testapp.local/
├── docs/                   # Documentation
│   ├── EC2_DEPLOYMENT.md
│   ├── RDS_TUNNEL.md
│   ├── LOCAL_SETUP.md
│   ├── API.md
│   ├── TESTING.md
│   └── screenshots/
└── .env.example            # Environment template
```

---

## 🔧 Configuration

### `.env` (Local)
```bash
# Docker Compose
COMPOSE_PROJECT_NAME=devstack
NGINX_PORT=80
PHP_VERSION=8.2
MYSQL_PORT=3306
PHPMYADMIN_PORT=8080
REDIS_PORT=6379

# Database (CHANGE THESE!)
DB_ROOT_PASSWORD=changeme
DB_NAME=devstack
DB_USER=devstack
DB_PASSWORD=changeme

# DStack Panel
APP_PORT=5000
```

### `cloud/config.env` (EC2)
See [cloud/config.env.example](cloud/config.env.example) and [docs/EC2_DEPLOYMENT.md](docs/EC2_DEPLOYMENT.md).

---

## 🧪 Testing

### Automated Test Suite
```bash
# Run all server tests
python3 server/test_services.py
python3 server/test_vhosts.py
python3 server/test_ssl.py
python3 server/test_rds_tunnel.py
python3 server/test_logs.py
python3 server/test_backup.py

# Or with pytest
python3 -m pytest server/test_*.py -v

# TUI tests
python3 -m pytest cli/test_tui.py -q

# Syntax checks
# PHP syntax check
php -l app/
bash -n cloud/*.sh
```

See [docs/TESTING.md](docs/TESTING.md) for detailed test scenarios and manual verification steps.

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [LOCAL_SETUP.md](docs/LOCAL_SETUP.md) | Detailed local installation guide |
| [EC2_DEPLOYMENT.md](docs/EC2_DEPLOYMENT.md) | AWS EC2 + RDS deployment guide |
| [RDS_TUNNEL.md](docs/RDS_TUNNEL.md) | SSH tunnel to RDS via EC2 bastion |
| [API.md](docs/API.md) | Complete API reference with curl examples |
| [TESTING.md](docs/TESTING.md) | Test scenarios + automated test runner |
| [screenshots/README.md](docs/screenshots/README.md) | Screenshot capture instructions |

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Run tests: `./vendor/bin/phpunit`
4. Commit changes: `git commit -m 'Add amazing feature'`
5. Push to branch: `git push origin feature/amazing-feature`
6. Open a Pull Request

### Code Style
- Python: `black` + `ruff` (see `pyproject.toml` if present)
- Shell: `shellcheck` clean
- JS: `eslint` (if configured)

---

## 🐛 Troubleshooting

| Issue | Solution |
|-------|----------|
| **Docker daemon not reachable** | `sudo systemctl start docker` + add user to `docker` group |
| **Port 80/443 in use** | Change `NGINX_PORT` in `.env` or stop conflicting service |
| **Panel won't start** | Check `devstack.log`, ensure port 5000 free, PHP deps installed |
| **Vhost not accessible** | Add `127.0.0.1 yourdomain.local` to `/etc/hosts` |
| **mkcert certs not trusted** | Run `mkcert -install` (requires `libnss3-tools` on Linux) |
| **RDS tunnel fails** | Verify EC2 SG allows SSH from your IP, RDS SG allows 3306 from EC2 SG |
| **Backup fails** | Check MySQL container is healthy, `DB_ROOT_PASSWORD` correct in `.env` |

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 🙏 Acknowledgments

- [Docker](https://docker.com) & [Docker Compose](https://docs.docker.com/compose/)
- [Laravel](https://laravel.com/) + [Symfony Process](https://symfony.com/doc/current/components/process.html)
- [nginx](https://nginx.org/) + [PHP-FPM](https://www.php.net/manual/en/install.fpm.php)
- [mkcert](https://github.com/FiloSottile/mkcert) for local TLS
- [ssh](https://man.openbsd.org/ssh) for SSH tunnels
- [phpMyAdmin](https://www.phpmyadmin.net/)

---

**Made with ❤️ for local PHP development**