# DStack Migration — Verification & Fix Plan

## Problem
All application code has been copied into DStack/, but verification has not been run. Inspection reveals critical issues that will prevent tests from passing.

## Tasks (ordered)

1. Fix `bootstrap/app.php`
   - Add `api: __DIR__.'/../routes/api.php'` to `withRouting()` so API routes register.

2. Fix unit test base classes
   - Update `tests/Unit/LogServiceTest.php`, `tests/Unit/RdsTunnelServiceTest.php` to extend `Tests\TestCase` instead of `PHPUnit\Framework\TestCase` so the Laravel application (and facades like `Config`) are available.

3. Fix static-call bug in VhostServiceTest
   - Update `tests/Unit/VhostServiceTest.php` to instantiate `VhostService` properly (via container or direct `new` after extending the correct TestCase) instead of calling `VhostService::renderVhost()` statically.

4. Run verification
   - `cd DStack && php vendor/bin/phpunit --testdox`
   - Fix any remaining test failures (target: 0 failures).

5. Final migration checks
   - `php artisan route:list`
   - `php artisan migrate --force`

## Risk
- `posix_kill()` in `RdsTunnelService` requires POSIX extension; if missing, unit tests using `disconnect()` / `getStatus()` may need mocking.
