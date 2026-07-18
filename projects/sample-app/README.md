# DStack Sample App

A minimal Laravel-style skeleton application for testing DStack virtual hosts.

## Purpose

This is a **lightweight sample project** that demonstrates how to structure a Laravel application for use with DStack. It's intentionally minimal — no `vendor/` directory, no compiled assets — just the essential files to show the expected structure.

## Structure

```
sample-app/
├── app/                    # Application code (empty - for your controllers/models)
├── bootstrap/
│   └── app.php            # Laravel application bootstrap
├── config/
│   └── app.php            # Application configuration
├── public/
│   └── index.php          # Front controller (entry point)
├── resources/
│   └── views/
│       └── welcome.blade.php  # Welcome page
├── routes/
│   └── web.php            # Web routes
├── storage/               # Logs, cache, sessions (create at runtime)
├── artisan                # Artisan CLI entry point
├── composer.json          # Dependencies (laravel/framework ^11.0)
├── .env.example           # Environment template
└── README.md              # This file
```

## Quick Start with DStack

### 1. Create a Virtual Host

Via the DStack dashboard (http://localhost:5000) or API:

```bash
curl -X POST http://localhost:5000/api/vhosts \
  -H "Content-Type: application/json" \
  -d '{"domain": "sample-app.local", "framework": "laravel"}'
```

### 2. Add to `/etc/hosts`

```bash
echo "127.0.0.1 sample-app.local" | sudo tee -a /etc/hosts
```

### 3. (Optional) Install Dependencies

If you want to run the full Laravel app:

```bash
cd projects/sample-app
composer install
cp .env.example .env
php artisan key:generate
```

### 4. Access the App

Open http://sample-app.local in your browser.

You should see the DStack welcome page with links to:
- **API Ping** — `/api/ping` (returns JSON)
- **Health Check** — `/api/health` (returns status)

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Welcome page |
| GET | `/api/ping` | Simple ping response |
| GET | `/api/health` | Health check |

## Notes

- This is a **skeleton only** — it won't run fully without `composer install`
- The `public/index.php` is a standard Laravel front controller
- The `artisan` file is a minimal CLI entry point
- For a real project, run `composer install` and configure `.env`

## Using as a Template

To create a new project from this skeleton:

```bash
cp -r projects/sample-app projects/my-new-app.local
# Edit projects/my-new-app.local/composer.json (name, etc.)
# Create vhost pointing to projects/my-new-app.local/public
```

---

*Part of [DStack](https://github.com/dgi-dev/DStack) — A Laragon-like local dev stack for PHP*