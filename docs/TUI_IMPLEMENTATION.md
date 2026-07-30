# DStack TUI (Text User Interface) Implementation

This document describes the Artisan command-line interface (CLI) and interactive TUI implementation for the DStack Panel Laravel application.

---

## Overview

The DStack TUI provides both **scriptable Artisan commands** for automation and an **interactive text-based menu** (`dstack:tui`) for manual operations. All commands operate over the existing `app/Services/` domain layer without duplicating business logic.

### Architecture

```
Artisan CLI (Symfony Console)
├── dstack:services:*         Docker Compose lifecycle
├── dstack:vhosts:*           Virtual host management
├── dstack:ssl:*              SSL certificate management
├── dstack:rds:*              RDS SSH tunnel management
├── dstack:backups:*          Backup and restore operations
├── dstack:logs               Log streaming
└── dstack:tui                Interactive TUI menu
```

Each command injects its relevant service via the constructor and returns `self::SUCCESS` or `self::FAILURE`. Services read configuration from `config('dstack.*')` and return structured arrays (`['success' => bool, 'message' => string, ...]`).

---

## Interactive Prompts with `laravel/prompts`

The interactive commands (`TuiCommand`, `VhostsDeleteCommand`, `BackupsRestoreCommand`) use the **`laravel/prompts` v0** package for enhanced terminal interactivity. This provides arrow-key navigation, search, and better visual formatting compared to Symfony Console's built-in prompts.

### Supported Prompt Functions

| Symfony Console | laravel/prompts | Use case |
|---|---|---|
| `$this->choice()` | `select()` | Single selection from a list |
| `$this->ask()` | `text()` | Free-text input |
| `$this->confirm()` | `confirm()` | Yes/No confirmation |
| `$this->info()` | `info()` | Success/info messages |
| `$this->error()` | `error()` | Error messages |
| `$this->warn()` | `warning()` | Warning messages |

### Function Imports

All `laravel/prompts` function imports use the `use function` syntax to be explicit about importing functions rather than classes:

```php
use function Laravel\Prompts\confirm;
use function Laravel\Prompts\error;
use function Laravel\Prompts\info;
use function Laravel\Prompts\select;
use function Laravel\Prompts\text;
```

### Non-Interactive Fallback

In non-interactive environments (e.g., CI pipelines, piped output), `laravel/prompts` detects that `STDIN` is not a TTY and automatically falls back to Symfony Console's question helper. This ensures commands remain testable via `artisan()->expectsChoice()`, `expectsQuestion()`, and `expectsConfirmation()`.

> **Note**: In non-interactive mode, `select()` without a default value will throw `NonInteractiveValidationException` because it is `required` by default. Always provide a `default` value for prompts used in testable command paths, or ensure prompts are faked in tests.

---

## Command Reference

### Phase 1 — Dashboard (Services)

| Command | Signature | Description |
|---|---|---|
| Services List | `dstack:services:list` | Display status table of all Docker Compose services |
| Services Start | `dstack:services:start {service=all}` | Start one or all services |
| Services Stop | `dstack:services:stop {service=all}` | Stop one or all services |
| Services Restart | `dstack:services:restart {service=all}` | Restart one or all services |

#### Return Shape Handling

All service methods return arrays with at minimum these keys:

```php
['success' => true, 'message' => 'OK']
['success' => false, 'message' => 'Error description']
```

Commands check `$result['success']` and output `$result['message']` with appropriate exit codes:

```php
if ($result['success']) {
    info($result['message']);  // or $this->info()
    return self::SUCCESS;
}

error($result['message']);  // or $this->error()
return self::FAILURE;
```

#### Example

```bash
php artisan dstack:services:list
php artisan dstack:services:start nginx
php artisan dstack:services:stop all
```

---

### Phase 2 — Virtual Hosts

| Command | Signature | Description |
|---|---|---|
| Vhosts List | `dstack:vhosts:list` | List all virtual hosts with domain, root, and framework |
| Vhosts Create | `dstack:vhosts:create {domain} {--root=} {--framework=php}` | Create a new virtual host |
| Vhosts Delete | `dstack:vhosts:delete {domain} {--remove-files}` | Delete a virtual host (with confirmation) |

#### VhostsCreateCommand Options

- `{domain}` (required) — The domain name (e.g., `example.local`)
- `--root` (optional) — The web root directory path
- `--framework` (optional, default: `php`) — Framework type (`php` or `laravel`)

#### VhostsDeleteCommand

- Requires `--remove-files` flag or interactive confirmation to proceed
- Uses `laravel/prompts\confirm()` for the confirmation prompt
- The service normalizes invalid frameworks to `'php'` and defaults `removeFiles` to `false`, so commands do not need to over-validate

---

### Phase 2 — SSL Certificates

| Command | Signature | Description |
|---|---|---|
| Ssl List | `dstack:ssl:list` | List all SSL certificates with status |
| Ssl Mkcert | `dstack:ssl:mkcert {domain}` | Create a self-signed certificate using mkcert |
| Ssl LetsEncrypt | `dstack:ssl:letsencrypt {domain} {email}` | Create a certificate using Let's Encrypt |

---

### Phase 3 — RDS Tunnel

| Command | Signature | Description |
|---|---|---|
| RDS Status | `dstack:rds:status` | Check if an RDS SSH tunnel is active |
| RDS Connect | `dstack:rds:connect {ec2-host} {ec2-user} {ec2-key-path} {rds-host} {--rds-port=3306} {--local-port=3307}` | Establish an SSH tunnel to RDS |
| RDS Disconnect | `dstack:rds:disconnect` | Terminate the active SSH tunnel |

#### RDS Connect Arguments

| Argument | Description |
|---|---|
| `{ec2-host}` | EC2 instance hostname or IP |
| `{ec2-user}` | SSH username |
| `{ec2-key-path}` | Filesystem path to the EC2 SSH private key |
| `{rds-host}` | RDS endpoint hostname |
| `--rds-port` | RDS port (default: `3306`) |
| `--local-port` | Local tunnel port (default: `3307`) |

---

### Phase 3 — Backups

| Command | Signature | Description |
|---|---|---|
| Backups List | `dstack:backups:list` | List all backups with metadata |
| Backups Create | `dstack:backups:create {--database=all} {--description=}` | Create a new backup |
| Backups Restore | `dstack:backups:restore {backup-id} {--database=}` | Restore from a backup (with confirmation) |

---

### Phase 4 — Logs

| Command | Signature | Description |
|---|---|---|
| Logs | `dstack:logs {service} {--lines=50} {--follow}` | View service logs with optional follow mode |

The `--follow` flag uses `Symfony\Component\Process\Process` directly (same pattern as `DStackHealth.php`) with a live output callback for `docker compose logs -f {service}`.

---

## Interactive TUI (`dstack:tui`)

The `TuiCommand` provides an interactive menu-driven interface that wraps all Phase 1–3 functionality. It is entered via:

```bash
php artisan dstack:tui
```

### Menu Structure

```
DStack Management
├── Dashboard    — Service status table with start/stop/restart actions
├── Vhosts       — List, create, or delete virtual hosts
├── SSL          — List certificates, create mkcert or Let's Encrypt certs
├── RDS Tunnel   — Check status, connect, or disconnect
├── Logs         — View service logs with configurable line count
├── Backups      — List, create, or restore backups
└── Exit         — Quit the TUI
```

### Implementation Details

- The TUI is implemented as a `while (true)` loop that re-renders the top-level menu after each action
- The `TuiCommand` constructor injects all 6 services directly (no service container binding needed)
- Interactive prompts use `laravel/prompts` functions (`select()`, `text()`, `confirm()`) for arrow-key navigation and better UX
- Static data display uses Symfony Console's `$this->table()`, `$this->info()`, and `$this->line()`
- Error handling displays messages via `error()` from `laravel/prompts` and returns appropriate exit codes

### TUI Navigation Patterns

```php
// Selection menu with arrow keys
$action = select('Action', ['Start Service', 'Stop Service', 'Restart Service', 'Back']);

// Free-text input with optional default
$service = text('Service name (or "all")');
$lines = (int) text('Number of lines', default: '50');

// Yes/No confirmation
if (! confirm("Delete virtual host '{$domain}'?")) {
    return self::SUCCESS;
}
```

---

## Testing

### Command Tests

Each command group has corresponding feature tests in `tests/Feature/`. Tests follow these patterns:

#### Non-Interactive Commands (Arguments/Options)

```php
// Test with arguments and options
$result = $this->artisan('dstack:vhosts:create', [
    'domain' => 'example.local',
    '--root' => '/custom/root',
    '--framework' => 'laravel',
]);
$result->assertExitCode(0);
```

#### TUI Commands (`expectsChoice`)

```php
// Laravel 12 expectsChoice requires 3 arguments: question, answer, choices array
$result = $this->artisan('dstack:tui')
    ->expectsChoice('DStack Management', 'Exit', ['Dashboard', 'Vhosts', 'SSL', 'RDS Tunnel', 'Logs', 'Backups', 'Exit']);
$result->assertExitCode(0);
```

#### Confirmation Prompts (`expectsConfirmation`)

```php
// expectsConfirmation takes question and expected boolean answer
$result = $this->artisan('dstack:backups:restore', ['backup-id' => '20260730_120000'])
    ->expectsConfirmation("Are you sure you want to restore backup '20260730_120000'?", true);
$result->assertExitCode(0);
```

#### Service Mocking

Commands that interact with external systems (Docker, RDS) are tested by mocking the service layer:

```php
$docker = $this->createMock(DockerComposeService::class);
$docker->method('getAllStatus')->willReturn([]);
$this->app->instance(DockerComposeService::class, $docker);
```

### Running Tests

```bash
# Run all tests
php artisan test --compact

# Run specific command tests
php artisan test --filter=ServicesListCommandTest
php artisan test --filter=TuiCommandTest

# Run tests for a specific file
php artisan test --compact tests/Feature/TuiCommandTest.php
```

---

## File Structure

```
app/Console/Commands/
├── DStackHealth.php                    # Health check command (standalone)
├── DStackSetup.php                     # First-run wizard (standalone)
├── DStackUpdate.php                    # Self-update command (standalone)
├── DstackVersionSync.php               # Version sync (standalone)
├── Services/
│   ├── ServicesListCommand.php         # dstack:services:list
│   ├── ServicesStartCommand.php        # dstack:services:start {service=all}
│   ├── ServicesStopCommand.php         # dstack:services:stop {service=all}
│   └── ServicesRestartCommand.php      # dstack:services:restart {service=all}
├── Vhosts/
│   ├── VhostsListCommand.php           # dstack:vhosts:list
│   ├── VhostsCreateCommand.php         # dstack:vhosts:create {domain} {--root} {--framework=php}
│   └── VhostsDeleteCommand.php         # dstack:vhosts:delete {domain} {--remove-files}
├── Ssl/
│   ├── SslListCommand.php              # dstack:ssl:list
│   ├── SslMkcertCommand.php            # dstack:ssl:mkcert {domain}
│   └── SslLetsEncryptCommand.php       # dstack:ssl:letsencrypt {domain} {email}
├── Rds/
│   ├── RdsStatusCommand.php            # dstack:rds:status
│   ├── RdsConnectCommand.php           # dstack:rds:connect {ec2-host} {ec2-user} {ec2-key-path} {rds-host} {--rds-port} {--local-port}
│   └── RdsDisconnectCommand.php        # dstack:rds:disconnect
├── Backups/
│   ├── BackupsListCommand.php          # dstack:backups:list
│   ├── BackupsCreateCommand.php        # dstack:backups:create {--database=all} {--description}
│   └── BackupsRestoreCommand.php       # dstack:backups:restore {backup-id} {--database}
├── Logs/
│   └── LogsCommand.php                 # dstack:logs {service} {--lines=50} {--follow}
└── Tui/
    └── TuiCommand.php                  # dstack:tui (interactive menu)

tests/Feature/
├── ServicesListCommandTest.php
├── ServicesStartCommandTest.php
├── ServicesStopCommandTest.php
├── ServicesRestartCommandTest.php
├── VhostsListCommandTest.php
├── VhostsCreateCommandTest.php
├── VhostsDeleteCommandTest.php
├── SslListCommandTest.php
├── SslMkcertCommandTest.php
├── SslLetsEncryptCommandTest.php
├── RdsStatusCommandTest.php
├── RdsConnectCommandTest.php
├── RdsDisconnectCommandTest.php
├── BackupsListCommandTest.php
├── BackupsCreateCommandTest.php
├── BackupsRestoreCommandTest.php
├── LogsCommandTest.php
└── TuiCommandTest.php
```

---

## Key Patterns and Conventions

### Service Return Shape

All services return `['success' => bool, 'message' => string, ...]`. Commands must check `$result['success']` before choosing exit code:

```php
$result = $this->dockerCompose->start($service);

if ($result['success']) {
    info($result['message']);
    return self::SUCCESS;
}

error($result['message']);
return self::FAILURE;
```

### Warnings Arrays

Some operations return `warnings` in addition to `success` and `message`. Commands should iterate and display these without failing the operation:

```php
if ($result['success']) {
    info("Virtual host '{$domain}' created.");
    if (! empty($result['warnings'])) {
        foreach ($result['warnings'] as $warning) {
            $this->warn("Warning: {$warning}");
        }
    }
    return self::SUCCESS;
}
```

### Command Auto-Discovery

Laravel auto-discovers commands in `app/Console/Commands/` and its subdirectories. No manual registration in `Kernel` or `routes/console.php` is needed.

### No Constructor Arguments for Services

Services are instantiated directly in command constructors with no arguments — they read `config('dstack.*')` internally:

```php
public function __construct(
    protected DockerComposeService $dockerCompose,
) {
    parent::__construct();
}
```

### Interactive TUI Does Not Call Other Commands

The `TuiCommand` does **not** call other commands via `$this->call()`. Instead, it instantiates and invokes service methods directly for cleaner control flow and better testability.

---

## Configuration

The DStack panel is configured via `config/dstack.php` and environment variables in `.env`. Key settings:

| Key | Default | Description |
|---|---|---|
| `dstack.root` | `/opt/dstack-panel` | Project root directory |
| `dstack.compose_file` | `/opt/dstack-panel/docker/docker-compose.yml` | Docker Compose file path |
| `dstack.env_file` | `/opt/dstack-panel/.env` | Environment file path |
| `dstack.vhosts_dir` | `/opt/dstack-panel/docker/vhosts` | Virtual host config directory |
| `dstack.ssl_dir` | `/opt/dstack-panel/docker/ssl` | SSL certificate directory |
| `dstack.projects_dir` | `/opt/dstack-panel/projects` | Project web root directory |
| `dstack.backups_dir` | `/opt/dstack-panel/backups` | Backup storage directory |
| `dstack.known_services` | `['nginx', 'php', 'mysql', 'phpmyadmin', 'redis', 'all'] | Valid service names for compose commands |
| `dstack.protected_services` | `['nginx'] | Services that cannot be stopped via `stopAllExceptProtected()` |

---

## Dependency Notes

- **`laravel/prompts` v0** is used for interactive prompts in `TuiCommand`, `VhostsDeleteCommand`, and `BackupsRestoreCommand`
- All other commands use only Symfony Console (bundled with Laravel) — no additional dependencies
- `laravel/prompts` automatically falls back to Symfony Console's question helpers in non-interactive environments, maintaining test compatibility
