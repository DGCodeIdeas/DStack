# DStack Existing EC2/RDS Bootstrap Guide

This guide covers bootstrapping an existing EC2 instance and RDS database for DStack using the unified `provision-ec2.sh --existing` entry point.

## Overview

If you already have an EC2 instance and RDS database running, use `provision-ec2.sh --existing` to bootstrap DStack directly onto your existing infrastructure. This is the recommended one-command workflow.

## Prerequisites

1. **AWS CLI** installed and configured on your local machine
2. **SSH key** matching the instance's key pair (default: `~/.ssh/<AWS_KEY_NAME>.pem`)
3. **`cloud/config.env`** populated with your values:
   - `AWS_REGION`
   - `RDS_ENDPOINT`
   - `RDS_PORT`
   - `RDS_DB_NAME`
   - `RDS_DB_USER`
   - `RDS_DB_PASSWORD`
   - `GITHUB_REPO_URL`
   - `SSH_USER`
   - `AWS_KEY_NAME`

## Quick Start

### Option 1: `provision-ec2.sh --existing` (Recommended)

```bash
# Auto-detect instance by tag (default tag: dstack-prod)
bash cloud/provision-ec2.sh --existing

# Specify a custom tag
bash cloud/provision-ec2.sh --existing --tag my-custom-tag

# Specify IP directly (skips AWS lookup)
bash cloud/provision-ec2.sh --existing --ip 203.0.113.10
```

This command will:

1. Validate `cloud/config.env`
2. Find the existing running instance (by tag or IP)
3. Generate a bootstrap script with injected config
4. SSH into the instance and run `cloud/bootstrap-existing.sh`
5. Print a completion summary with next steps

### Option 2: `setup-existing-ec2.sh` (Alternative)

If `provision-ec2.sh --existing` does not fit your workflow, you can use the standalone tag-based handler:

```bash
# From your local machine
bash cloud/setup-existing-ec2.sh
```

This will:

1. Find your running EC2 instance by tag
2. Generate a bootstrap script at `cloud/output/bootstrap-existing.sh`
3. Print the SSH command to run

Then run the generated bootstrap:

```bash
ssh -i ~/.ssh/<AWS_KEY_NAME>.pem <SSH_USER>@<YOUR_IP> 'sudo bash -s' < cloud/output/bootstrap-existing.sh
```

### Option 3: Manual Upload

1. Copy `cloud/bootstrap-existing.sh` to your EC2 instance:
   ```bash
   scp -i ~/.ssh/<AWS_KEY_NAME>.pem cloud/bootstrap-existing.sh ubuntu@<YOUR_IP>:/tmp/
   ```

2. SSH into the instance:
   ```bash
   ssh -i ~/.ssh/<AWS_KEY_NAME>.pem ubuntu@<YOUR_IP>
   ```

3. Export config values:
   ```bash
   export GITHUB_REPO_URL="https://github.com/yourusername/DStack.git"
   export RDS_ENDPOINT="your-rds-endpoint.region.rds.amazonaws.com"
   export RDS_DB_NAME="dstack"
   export RDS_DB_USER="admin"
   export RDS_DB_PASSWORD="your-password"
   ```

4. Run the bootstrap:
   ```bash
   sudo bash /tmp/bootstrap-existing.sh
   ```

## What the Bootstrap Does

The bootstrap script (`cloud/bootstrap-existing.sh`) will:

1. **Install Docker** (idempotently — skips if already installed)
2. **Configure Docker daemon** (DNS settings for builds)
3. **Create swap** (2GB for imagick PECL compile)
4. **Stop conflicting services** (apache2, nginx on port 80)
5. **Install Certbot** (for Let's Encrypt SSL)
6. **Clone the DStack repository** to `/opt/dstack`
7. **Create `.env` file** with your RDS configuration
8. **Create `docker-compose.override.yml`** to disable local MySQL and point phpMyAdmin to RDS
9. **Start Docker Compose services** (`docker compose up --build -d`)
10. **Configure SSL** (if `DOMAIN` and `EMAIL_FOR_LETSENCRYPT` are set)

## Monitoring Progress

Once the bootstrap starts, monitor it with:

```bash
ssh -i ~/.ssh/<AWS_KEY_NAME>.pem <SSH_USER>@<YOUR_IP> 'tail -f /var/log/dstack-bootstrap.log'
```

Expected milestones:

| Time | Milestone |
|------|-----------|
| 0:00 | Configuration validated |
| 0:30 | Docker installed |
| 1:00 | Swap created, port 80 freed |
| 1:30 | Repo cloned, `.env` written |
| 2:00 | `docker compose up --build` starts |
| ~17:00 | imagick PECL compile finishes |
| ~18:00 | All containers up, bootstrap complete |

## After Bootstrap

Once bootstrap completes, continue with the remaining phases:

1. **Verify containers**:
   ```bash
   ssh -i ~/.ssh/<AWS_KEY_NAME>.pem <SSH_USER>@<YOUR_IP>
   cd /opt/dstack/docker
   sudo docker compose ps
   ```

2. **Create the database**:
   ```bash
   mysql -h <RDS_ENDPOINT> -u <RDS_USER> -p -e "CREATE DATABASE IF NOT EXISTS chada_digital CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
   ```

3. **Deploy the app**: Follow the original guide for app deployment, DNS, and SSL.

## Troubleshooting

### No Instance Found by Tag

- Verify the instance is running: `aws ec2 describe-instances --region <AWS_REGION> --filters "Name=tag:Name,Values=dstack-prod" "Name=instance-state-name,Values=running"`
- Use `--ip` to target a specific instance directly instead of tag lookup

### SSH Connection Refused

- Verify the instance is running: `aws ec2 describe-instances --instance-ids <ID> --region <REGION>`
- Check security group allows port 22 from your IP
- Verify the key pair name matches your `.pem` file

### Docker Build Fails

- Check `/var/log/dstack-bootstrap.log` for errors
- The imagick PECL compile requires swap — ensure 2GB swap is created
- DNS issues: verify `/etc/docker/daemon.json` has Google DNS

### RDS Connection Failed

- Verify RDS security group allows inbound traffic from the EC2 security group on port 3306
- Check RDS endpoint, port, username, and password in `cloud/config.env`
- Test from EC2: `mysql -h <RDS_ENDPOINT> -u <USER> -p`
