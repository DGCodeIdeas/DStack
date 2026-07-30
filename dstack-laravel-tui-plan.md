# DStack Panel — Laravel TUI Option
### Plan · while Web UI/UX is still in development

---

## 1. Goal

A terminal interface to the same DStack Panel functionality the web UI exposes — usable today, stable regardless of ongoing web UI churn, and requiring no duplicate logic.

**Non-goal:** this is not a replacement for the web panel, and not a rebuild of the old Python `cli/tui.py` (deleted in the Laravel migration). It's a second, thin presentation layer over the *same* domain services the web UI already calls.

---

## 2. The one architectural decision that makes this cheap

`app/Services/` already contains the entire domain layer, independent of HTTP:

| Service | Real methods (verified against current code) |
|---|---|
| `DockerComposeService` | `getAllStatus()`, `start(string $service = 'all')`, `stop(string $service = 'all')`, `restart(string $service = 'all')`, `stopAllExceptProtected()` |
| `VhostService` | `create(string $domain, ?string $root, string $framework)`, `delete(string $domain, bool $removeFiles)`, `listAll()` |
| `SslService` | `createMkcert(string $domain)`, `createLetsEncrypt(string $domain, string $email, ...)`, `enableVhostSsl(...)`, `listCerts()` |
| `RdsTunnelService` | `connect(string $ec2Host, string $ec2User, string $ec2KeyPath, string $rdsHost, int $rdsPort, int $localPort)`, `disconnect()`, `getStatus()` |
| `BackupService` | `backup(string $database, string $description)`, `listBackups()`, `getBackup(string $backupId)`, `restore(string $backupId, ?string $database)` |
| `LogService` | `getLogs(string $service, int $lines)`, `parseLogsOutput(string $raw)` |

The web `Controllers/` are thin — they inject one of these, call a method, return JSON. **Artisan commands do exactly the same thing, just rendering to a terminal instead of a JSON response.** Zero domain logic gets written twice; a bug fix in `RdsTunnelService::connect()` fixes both interfaces simultaneously. This is also why the TUI is safe to build *now*, in parallel with web UI/UX changes — Blade templates and JS can keep changing without touching a single service class the TUI depends on.

There's already precedent for this exact pattern in the codebase: `app/Console/Commands/DStackHealth.php` is a `Command` that shells out via `Symfony\Process` directly, following Laravel's standard `protected $signature` / `handle(): int` shape. New commands should match that style.

---

## 3. Dependency decision

Given the stated preference for minimal dependencies, three tiers, in order of recommendation:

**Tier 1 — zero new dependencies.** Symfony Console (bundled with every Laravel app via Artisan) already provides `$this->table()`, `$this->choice()`, `$this->ask()`, `$this->confirm()`, and progress bars. This alone covers scriptable one-shot commands (`dstack:services:list`, `dstack:vhosts:create ...`) and even a basic numbered-menu interactive mode. No `composer require` at all.

**Tier 2 — `laravel/prompts` (recommended).** One package, maintained by the Laravel core team itself (used by Laravel's own installer), zero transitive bloat, purpose-built for exactly this: arrow-key `select()`/`multiselect()`, `spin()` for the RDS tunnel connect step, `table()`, validated `text()`/`password()` inputs. This is the difference between "a CLI with a menu" and something that actually feels like a TUI. Given it's official and tiny, it doesn't meaningfully work against the minimal-dependency goal the way a random community package would.

**Tier 3 — `php-tui/php-tui` (optional, later, not now).** A genuine full-screen terminal UI framework (ratatui-inspired) for persistent, live-refreshing panels — e.g., a services dashboard that updates in place rather than reprinting. Real dependency weight and a steeper build for a capability that wasn't asked for (an always-open live dashboard vs. a menu you navigate). Worth revisiting only if "watch things update live in a terminal pane" becomes an actual want, not a nice-to-have.

**Recommendation: start Tier 1, add Tier 2 once the basic commands work.** This means the very first working version requires no new `composer.json` entries at all.

---

## 4. Command structure

Two layers, both calling the same services:

**Scriptable one-shot commands** (for automation, cron, quick terminal use):
```
dstack:services:list
dstack:services:start   {service=all}
dstack:services:stop    {service=all}
dstack:services:restart {service=all}
dstack:vhosts:list
dstack:vhosts:create    {domain} {--root=} {--framework=php}
dstack:vhosts:delete    {domain} {--remove-files}
dstack:ssl:list
dstack:ssl:mkcert       {domain}
dstack:ssl:letsencrypt  {domain} {email}
dstack:rds:status
dstack:rds:connect      {ec2-host} {ec2-user} {ec2-key-path} {rds-host} {--rds-port=3306} {--local-port=3307}
dstack:rds:disconnect
dstack:backups:list
dstack:backups:create   {--database=all} {--description=}
dstack:backups:restore  {backup-id} {--database=}
dstack:logs             {service} {--lines=50} {--follow}
```

**One interactive entry point**, mirroring the web panel's own sidebar structure directly:
```
dstack:tui
```
opening a `select()` menu: Dashboard -> Vhosts -> SSL -> RDS Tunnel -> Logs -> Backups -> Exit -- the exact same six sections as the web sidebar, just navigated with arrow keys instead of clicks. Each selection drops into a sub-menu (e.g., Dashboard -> `getAllStatus()` rendered as a `table()`, then a follow-up `select()` for which service to act on and which action).

---

## 5. Section-by-section design

**Dashboard** — `DockerComposeService::getAllStatus()` rendered as a table (service, status, uptime). Action menu below calls `start('all')`/`stop('all')` for bulk, or per-row `restart($name)` — the same `string $service = 'all'` signature that already backs the web UI's "Start All"/"Stop All" buttons, so no branching logic needed for bulk vs. single.

**Vhosts** — `listAll()` as a table; "Add" flow prompts domain -> root path (optional) -> framework, calls `create()`; per-row delete prompts a confirm (mentioning `removeFiles`) before calling `delete()`.

**SSL** — `listCerts()` as a table; "Add" flow offers a `select()` between Local (mkcert) and Let's Encrypt, then the relevant prompts, calling `createMkcert()` or `createLetsEncrypt()`.

**RDS Tunnel** — `getStatus()` shown as a colored badge-equivalent (`<fg=green>Connected</>` / `<fg=red>Disconnected</>` / `<fg=gray>Unknown</>` using Symfony Console's inline tag syntax, mirroring the same three-state semantic color system from the web UI refinement). Connect flow prompts the six fields, grouped the same way as the refined web form (SSH connection: host/user/key path; RDS connection: host/port/local port), wrapped in `spin()` while `connect()` runs.

**Logs** — `select()` to choose a service, then `getLogs($service, $lines)`. For `--follow`, don't reuse the web's SSE endpoint — that's solving a different problem (multiple browser clients). Simplest and most correct for a single terminal session: run `docker compose logs -f {service}` directly via `Symfony\Process` with a live output callback (`$process->run(fn ($type, $buffer) => $this->output->write($buffer))`), same underlying command the web SSE stream wraps, just without the multi-client broadcasting overhead a terminal doesn't need.

**Backups** — `listBackups()` as a table; create flow prompts database + description, calls `backup()`; restore flow lists backups via `select()`, confirms, calls `restore()`.

---

## 6. Testing

The domain services already carry 74 passing tests — the TUI layer needs far less. Laravel's console testing helpers cover it directly:
```php
$this->artisan('dstack:services:start', ['service' => 'nginx'])
     ->assertExitCode(0);
```
For interactive `dstack:tui` flows, `expectsQuestion()` / `expectsChoice()` chains simulate the prompt sequence. No need to test `DockerComposeService::start()` again here — that's already covered; the TUI tests just confirm the command wires arguments to the right method and handles its return shape.

---

## 7. Files to create

```
app/Console/Commands/
  Services/ServicesListCommand.php, ServicesStartCommand.php, ServicesStopCommand.php, ServicesRestartCommand.php
  Vhosts/VhostsListCommand.php, VhostsCreateCommand.php, VhostsDeleteCommand.php
  Ssl/SslListCommand.php, SslMkcertCommand.php, SslLetsEncryptCommand.php
  Rds/RdsStatusCommand.php, RdsConnectCommand.php, RdsDisconnectCommand.php
  Backups/BackupsListCommand.php, BackupsCreateCommand.php, BackupsRestoreCommand.php
  Logs/LogsCommand.php
  Tui/TuiCommand.php          <- the interactive entry point, dispatches to the above
```
All follow the existing `DStackHealth.php` shape: `protected $signature`, `protected $description`, `handle(): int`, constructor-injected service.

---

## 8. Rollout order

1. **Dashboard commands** (services list/start/stop/restart) — highest daily-use value, simplest to build, zero new dependencies.
2. **Vhosts + SSL** — second-highest use frequency.
3. **RDS Tunnel + Backups** — less frequent but higher-stakes actions; worth the `spin()`/confirm() polish from `laravel/prompts` once added.
4. **Logs + the unified `dstack:tui` menu** wrapping everything — built last since it depends on all the individual commands existing first.

Each phase is independently useful and shippable — there's no point where the TUI is "half-built and useless."

---

## 9. Retirement criteria

This isn't meant to be permanent scaffolding-forever. Worth revisiting once the web UI's nav restructuring lands and stabilizes: if the web panel becomes the daily-driver for every section, the TUI's value narrows to "quick actions without opening a browser" and headless/SSH-only scenarios — both legitimate reasons to keep it, but worth explicitly deciding rather than maintaining two interfaces by default indefinitely.
