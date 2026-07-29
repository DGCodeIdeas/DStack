# DStack Panel

DStack Panel — Laravel 12 panel for managing Docker services, SSL, backups, logs, and virtual hosts.

## Documentation

| Document | Description |
|----------|-------------|
| [Getting Started](./docs/getting-started.md) | Prerequisites, installation, local development setup |
| [Architecture](./docs/architecture.md) | Project structure, blue-green runtime, data flow |
| [API Reference](./docs/api.md) | REST endpoints, SSE streams, usage examples |
| [Deployment](./docs/deployment.md) | EC2 blue-green setup, CI/CD, versioning |
| [Troubleshooting](./docs/troubleshooting.md) | Common issues, error codes, recovery procedures |

## Quick Start

```bash
# Clone
git clone https://github.com/DGCodeIdeas/DStack.git
cd DStack

# Install dependencies
composer install
bun install --frozen-lockfile

# Configure
cp .env.example .env
php artisan key:generate
php artisan migrate --force

# Build assets
bun run dev

# Start server
php artisan serve --host=0.0.0.0 --port=5000
```

## Production Deployment

DStack Panel uses **blue-green rolling updates** on a single EC2 host behind nginx.

```bash
# SSH to EC2
ssh -i ~/.ssh/chadadigital.pem ubuntu@13.62.47.161

# Run init script
bash init.sh
```

See [Deployment](./docs/deployment.md) for full instructions.

## Versioning

This project follows [Semantic Versioning](https://semver.org/).

- **MAJOR**: breaking API/route/auth/DB changes
- **MINOR**: new endpoints, features, backwards-compatible configs
- **PATCH**: bug fixes, UI tweaks, hardening

Sync version from git tags:

```bash
php artisan dstack:version-sync --publish
```
