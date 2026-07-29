> [!WARNING]
> This document describes the legacy Flask-based architecture and is no longer accurate.
> For current documentation, see the [Documentation Index](./README.md).

# DStack Testing Guide

This document describes the test scenarios for manual verification and the automated test suite.

---

## Automated Test Suite

### Running All Tests

```bash
# Run all server tests individually
python3 server/test_services.py
python3 server/test_vhosts.py
python3 server/test_ssl.py
python3 server/test_rds_tunnel.py
python3 server/test_logs.py
python3 server/test_backup.py

# Or with pytest (recommended)
python3 -m pytest server/test_*.py -v

# Run TUI tests
python3 -m pytest cli/test_tui.py -q

# Syntax checks
python3 -m py_compile server/*.py cli/*.py
node --check web-ui/js/app.js   # if node is available
bash -n cloud/*.sh
```

### Test Coverage Summary

| Test File | Module | Coverage |
|-----------|--------|----------|
| `test_services.py` | `services.ServiceManager` | Service status, start/stop/restart, docker command detection |
| `test_vhosts.py` | `virtual_hosts.VirtualHostManager` | Create/list/delete vhosts, domain validation, template rendering, hosts file |
| `test_ssl.py` | `ssl_manager.SSLManager` | mkcert/LE cert generation, cert listing, status, nginx config injection |
| `test_rds_tunnel.py` | `rds_tunnel.RDSTunnel` | Paramiko tunnel, validation, reconnect watcher, status |
| `test_logs.py` | `logs_aggregator.LogAggregator` | Log fetching, streaming, parsing, line coercion |
| `test_backup.py` | `backup_restore.BackupManager` | Backup/restore/list, manifest, pipeline execution |
| `test_tui.py` | `cli.tui` | TUI rendering, key bindings, navigation |

---

## Manual Test Scenarios

These scenarios verify end-to-end functionality. Run them after a fresh install (`./cloud/install-local.sh`).

---

### Scenario 1: Create VHost → Access App → View Logs

**Objective**: Verify the full vhost lifecycle from creation to access and log inspection.

**Prerequisites**: DStack stack running (`docker compose up -d`), Flask API on port 5000.

**Steps:**

1. **Create a Laravel vhost via API**
   ```bash
   curl -s -X POST http://localhost:5000/api/vhosts \
     -H "Content-Type: application/json" \
     -d '{"domain": "testapp.local", "framework": "laravel"}'
   ```
   Expected: `{"success": true, "domain": "testapp.local", ...}`

2. **Add to `/etc/hosts`** (if not auto-added)
   ```bash
   echo "127.0.0.1 testapp.local" | sudo tee -a /etc/hosts
   ```

3. **Verify the project directory was created**
   ```bash
   ls -la projects/testapp.local/public/
   # Should show index.php
   ```

4. **Access the vhost in browser or curl**
   ```bash
   curl -s http://testapp.local | grep -i "devstack"
   # Should return the starter page HTML
   ```

5. **Generate a local SSL cert (optional)**
   ```bash
   curl -s -X POST http://localhost:5000/api/ssl/local \
     -H "Content-Type: application/json" \
     -d '{"domain": "testapp.local"}'
   ```

6. **Access via HTTPS** (if mkcert CA trusted)
   ```bash
   curl -k https://testapp.local | grep -i "devstack"
   ```

7. **View nginx access logs via API**
   ```bash
   curl -s "http://localhost:5000/api/logs/nginx?lines=20" | jq '.lines[]'
   # Should show your GET request to testapp.local
   ```

8. **Stream live logs**
   ```bash
   curl -N http://localhost:5000/api/logs/nginx/stream
   # In another terminal: curl http://testapp.local
   # New log lines appear in real time
   ```

**Pass Criteria:**
- Vhost created successfully
- Domain resolves and serves PHP page
- Logs capture the request
- Live streaming works

---

### Scenario 2: Backup Database → Restore → Verify

**Objective**: Verify backup and restore functionality for MySQL databases.

**Prerequisites**: MySQL container healthy, `.env` has correct `DB_ROOT_PASSWORD`.

**Steps:**

1. **Create test data in MySQL**
   ```bash
   docker compose -f docker/docker-compose.yml exec -T mysql mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
   CREATE DATABASE IF NOT EXISTS testdb;
   USE testdb;
   CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100));
   INSERT INTO users (name) VALUES ('Alice'), ('Bob');
   SELECT * FROM users;
   "
   ```

2. **Create a backup via API**
   ```bash
   curl -s -X POST http://localhost:5000/api/backup \
     -H "Content-Type: application/json" \
     -d '{"database": "testdb", "description": "Test backup before changes"}'
   ```
   Expected: `{"success": true, "backup_id": "20260718_120000", ...}`

3. **List backups**
   ```bash
   curl -s http://localhost:5000/api/backups | jq
   # Should show the new backup with database: "testdb"
   ```

4. **Verify backup file exists and is non-empty**
   ```bash
   ls -lh backups/20260718_120000/
   # Should show testdb.sql.gz > 0 bytes
   zcat backups/20260718_120000/testdb.sql.gz | head -20
   # Should show CREATE TABLE and INSERT statements
   ```

5. **Modify the data (simulate corruption/change)**
   ```bash
   docker compose -f docker/docker-compose.yml exec -T mysql mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
   USE testdb;
   DELETE FROM users;
   INSERT INTO users (name) VALUES ('Eve');
   SELECT * FROM users;
   "
   # Should show only 'Eve'
   ```

6. **Restore the backup via API**
   ```bash
   curl -s -X POST http://localhost:5000/api/restore \
     -H "Content-Type: application/json" \
     -d '{"backup_id": "20260718_120000"}'
   ```
   Expected: `{"success": true, "message": "Restore from '20260718_120000' completed."}`

7. **Verify data restored**
   ```bash
   docker compose -f docker/docker-compose.yml exec -T mysql mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
   USE testdb;
   SELECT * FROM users;
   "
   # Should show 'Alice' and 'Bob' again
   ```

8. **Test restore to different database name**
   ```bash
   curl -s -X POST http://localhost:5000/api/restore \
     -H "Content-Type: application/json" \
     -d '{"backup_id": "20260718_120000", "database": "testdb_restored"}'
   
   docker compose -f docker/docker-compose.yml exec -T mysql mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
   USE testdb_restored;
   SELECT * FROM users;
   "
   # Should show 'Alice' and 'Bob' in the new database
   ```

**Pass Criteria:**
- Backup creates timestamped directory with `.sql.gz` and `manifest.json`
- Restore returns success
- Original data is recovered exactly
- Restore to different database name works

---

### Scenario 3: RDS Tunnel → Query Remote Database

**Objective**: Verify SSH tunnel from local machine → EC2 bastion → RDS.

**Prerequisites:**
- EC2 instance running with SSH access
- RDS instance in same VPC, security group allows 3306 from EC2 SG
- SSH key pair (private key on local machine, public key in EC2 `authorized_keys`)

**Steps:**

1. **Verify EC2 SSH access**
   ```bash
   ssh -i ~/.ssh/devstack-ec2 ec2-user@<EC2_PUBLIC_IP> "echo 'SSH OK'"
   ```

2. **Verify RDS reachable from EC2**
   ```bash
   ssh -i ~/.ssh/devstack-ec2 ec2-user@<EC2_PUBLIC_IP> \
     "mysql -h <RDS_ENDPOINT> -u <RDS_USER> -p -e 'SELECT 1'"
   ```

3. **Start tunnel via API**
   ```bash
   curl -s -X POST http://localhost:5000/api/rds/tunnel/start \
     -H "Content-Type: application/json" \
     -d '{
       "ec2_host": "<EC2_PUBLIC_IP>",
       "ec2_user": "ec2-user",
       "ec2_key_path": "/home/user/.ssh/devstack-ec2",
       "rds_host": "<RDS_ENDPOINT>",
       "rds_port": 3306,
       "local_port": 3307
     }'
   ```
   Expected: `{"success": true, "local_port": 3307, ...}`

4. **Check tunnel status**
   ```bash
   curl -s http://localhost:5000/api/rds/tunnel/status | jq
   # Should show "connected": true, "transport_active": true
   ```

5. **Connect to RDS via local tunnel**
   ```bash
   mysql -h 127.0.0.1 -P 3307 -u <RDS_USER> -p
   # Should connect to remote RDS as if local
   ```

6. **Run a query**
   ```sql
   SHOW DATABASES;
   SELECT VERSION();
   ```

7. **Stop tunnel**
   ```bash
   curl -s -X POST http://localhost:5000/api/rds/tunnel/stop
   curl -s http://localhost:5000/api/rds/tunnel/status | jq
   # Should show "connected": false
   ```

**Pass Criteria:**
- Tunnel starts without error
- Status shows connected
- Local MySQL client connects through tunnel to RDS
- Queries execute successfully
- Tunnel stops cleanly

> **Note**: In CI/sandbox without real EC2/RDS, the unit tests in `test_rds_tunnel.py` mock the paramiko transport and validate the logic.

---

### Scenario 4: SSL Certificate Generation → HTTPS Access

**Objective**: Verify both mkcert (local) and Let's Encrypt (production) certificate workflows.

**Prerequisites:**
- mkcert installed and CA trusted (`mkcert -install`)
- For Let's Encrypt: real domain pointing to server, port 80 open

#### Part A: Local mkcert Certificate

1. **Create vhost**
   ```bash
   curl -s -X POST http://localhost:5000/api/vhosts \
     -H "Content-Type: application/json" \
     -d '{"domain": "secure.local", "framework": "php"}'
   echo "127.0.0.1 secure.local" | sudo tee -a /etc/hosts
   ```

2. **Generate mkcert certificate**
   ```bash
   curl -s -X POST http://localhost:5000/api/ssl/local \
     -H "Content-Type: application/json" \
     -d '{"domain": "secure.local"}'
   ```
   Expected: `{"success": true, "vhost_enabled": true, ...}`

3. **Verify cert files exist**
   ```bash
   ls -la docker/ssl/secure.local*
   # Should show secure.local.pem and secure.local-key.pem
   ```

4. **Verify nginx config includes SSL block**
   ```bash
   cat docker/vhosts/secure.local.conf
   # Should have a server { listen 443 ssl; ... } block
   ```

5. **Access via HTTPS**
   ```bash
   curl -k https://secure.local | grep -i "devstack"
   # -k needed if browser doesn't trust mkcert CA yet
   ```

6. **Verify certificate details**
   ```bash
   openssl x509 -in docker/ssl/secure.local.pem -text -noout | grep -A1 "Subject:"
   # Should show CN=secure.local
   ```

#### Part B: Let's Encrypt Certificate (Production)

> **Requires**: Public domain with A record pointing to server IP, port 80 accessible.

1. **Request Let's Encrypt cert**
   ```bash
   curl -s -X POST http://localhost:5000/api/ssl/letsencrypt \
     -H "Content-Type: application/json" \
     -d '{
       "domain": "app.example.com",
       "email": "admin@example.com",
       "mode": "standalone"
     }'
   ```
   Expected: `{"success": true, "vhost_enabled": true, ...}`

2. **Verify cert is valid and trusted**
   ```bash
   curl -I https://app.example.com
   # Should return 200 with valid cert chain
   
   openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null \
     | openssl x509 -noout -dates
   # Should show valid notBefore/notAfter
   ```

3. **Verify auto-renewal cron** (on EC2)
   ```bash
   ssh ubuntu@<EC2_IP> "crontab -l | grep certbot"
   # Should show daily renewal job
   ```

**Pass Criteria:**
- mkcert: cert generated, nginx HTTPS block added, HTTPS works (with `-k` or trusted CA)
- Let's Encrypt: cert obtained, nginx configured, browser trusts cert, auto-renewal scheduled

---

## Test Data Cleanup

After running scenarios, clean up test artifacts:

```bash
# Remove test vhosts
curl -X DELETE http://localhost:5000/api/vhosts/testapp.local
curl -X DELETE http://localhost:5000/api/vhosts/secure.local

# Remove test backups
rm -rf backups/20260718_*

# Remove test databases
docker compose -f docker/docker-compose.yml exec -T mysql mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
DROP DATABASE IF EXISTS testdb;
DROP DATABASE IF EXISTS testdb_restored;
"

# Stop RDS tunnel if running
curl -X POST http://localhost:5000/api/rds/tunnel/stop
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
# .github/workflows/test.yml
name: Test Suite

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      docker:
        image: docker:24-dind
        options: --privileged
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - name: Install dependencies
        run: |
          pip install -r server/requirements.txt
          pip install pytest paramiko pyyaml python-dotenv
      - name: Run server tests
        run: python3 -m pytest server/test_*.py -v
      - name: Run TUI tests
        run: python3 -m pytest cli/test_tui.py -q
      - name: Syntax checks
        run: |
          python3 -m py_compile server/*.py cli/*.py
          bash -n cloud/*.sh
```

---

## Troubleshooting Tests

| Issue | Solution |
|-------|----------|
| `docker compose` not found | Install Docker Compose v2 plugin |
| `paramiko` import error | `pip install paramiko` |
| Tests hang on Docker calls | Ensure Docker daemon is running; increase timeout in test files |
| MySQL connection refused in tests | Wait for healthcheck; `docker compose ps` should show `healthy` |
| mkcert tests fail | Install `libnss3-tools` and run `mkcert -install` |
| Permission denied on `/etc/hosts` | Tests handle this gracefully (warnings only); run with sudo if needed |

---

## Adding New Tests

1. Create `server/test_<module>.py` following existing patterns
2. Use pure helper functions for testable logic
3. Mock external dependencies (Docker, SSH, filesystem)
4. Add to the pytest suite
5. Document new scenario in this file