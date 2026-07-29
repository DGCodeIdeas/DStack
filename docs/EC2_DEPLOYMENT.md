> [!WARNING]
> This document describes the legacy Flask-based architecture and is no longer accurate.
> For current documentation, see the [Documentation Index](./README.md).

# DStack EC2 Deployment Guide

This guide walks you through deploying the full DStack development stack to an AWS EC2 instance using Docker Compose.

## Prerequisites

### AWS Account & IAM Permissions

You need an AWS account with an IAM user/role that has the following permissions. Create a policy with this JSON and attach it to your IAM user/role:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EC2InstanceManagement",
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceStatus",
                "ec2:DescribeImages",
                "ec2:DescribeKeyPairs",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcs",
                "ec2:CreateTags",
                "ec2:Wait"
            ],
            "Resource": "*"
        },
        {
            "Sid": "SecurityGroupManagement",
            "Effect": "Allow",
            "Action": [
                "ec2:CreateSecurityGroup",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:AuthorizeSecurityGroupEgress",
                "ec2:RevokeSecurityGroupIngress",
                "ec2:DeleteSecurityGroup"
            ],
            "Resource": "*"
        },
        {
            "Sid": "SSMParameterAccess",
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters"
            ],
            "Resource": "arn:aws:ssm:*:*:parameter/aws/service/canonical/ubuntu/server/*"
        },
        {
            "Sid": "STSCallerIdentity",
            "Effect": "Allow",
            "Action": [
                "sts:GetCallerIdentity"
            ],
            "Resource": "*"
        }
    ]
}
```

### Required AWS Resources (Create Beforehand)

1. **EC2 Key Pair** - Create in your target region:
   ```bash
   aws ec2 create-key-pair --key-name dstack-key --region us-east-1 --query 'KeyMaterial' --output text > ~/.ssh/dstack-key.pem
   chmod 400 ~/.ssh/dstack-key.pem
   ```

2. **RDS Database** - Create an RDS instance (MySQL/MariaDB):
   - Engine: MySQL 8.0 or MariaDB 10.6+
   - Instance class: db.t3.micro (free tier) or larger
   - Storage: 20 GB minimum
   - **Important**: Place in a VPC with a security group that allows inbound 3306 from the EC2 security group (created by the script)
   - Note the endpoint, port, database name, master username, and password

3. **GitHub Repository** - Push your DStack code to a GitHub repository (public or private with PAT)

## Step-by-Step Deployment

### 1. Configure Environment

```bash
# Navigate to the DStack project root
cd /path/to/DStack

# Copy the example config
cp cloud/config.env.example cloud/config.env

# Edit with your values
vim cloud/config.env
```

**Required values in `config.env`:**
- `AWS_REGION` - e.g., `us-east-1`
- `AWS_INSTANCE_TYPE` - `t3.small` (default, NOT free tier after 12 months) or `t3.micro` (free tier)
- `AWS_KEY_NAME` - Your EC2 key pair name
- `RDS_ENDPOINT` - Your RDS endpoint (e.g., `mydb.xxxxxxx.us-east-1.rds.amazonaws.com`)
- `RDS_DB_NAME` - Database name (e.g., `dstack`)
- `RDS_DB_USER` - RDS master username
- `RDS_DB_PASSWORD` - RDS master password
- `GITHUB_REPO_URL` - Your GitHub repo URL (HTTPS)
- `SSH_USER` - `ubuntu` (for Ubuntu AMI)
- `SECURITY_GROUP_NAME` - `dstack-sg` (will be created)
- `INSTANCE_NAME_TAG` - `devstack-prod`
- `AMI_ID` - Ubuntu 22.04 LTS AMI for your region (see below)
- `ROOT_VOLUME_SIZE` - `20` (GB)

**Optional but recommended for production:**
- `DOMAIN` - Your domain (e.g., `dstack.example.com`)
- `EMAIL_FOR_LETSENCRYPT` - Email for SSL certificates
- `GITHUB_TOKEN` - For private repos (use HTTPS URL with token)
- `GITHUB_BRANCH` - Branch to deploy (default: `main`)

### 2. Find the Correct AMI ID

The script uses a hardcoded AMI for Ubuntu 22.04 LTS in `us-east-1`. For other regions, find the current AMI:

```bash
# Ubuntu 22.04 LTS (Jammy) AMD64
aws ssm get-parameter \
    --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
    --region YOUR_REGION \
    --query 'Parameter.Value' --output text
```

Update `AMI_ID` in `config.env` with the result.

### 3. Run Provisioning Script

```bash
# Make executable (if not already)
chmod +x cloud/provision-ec2.sh cloud/ec2-setup.sh

# Run provisioning
bash cloud/provision-ec2.sh
```

The script will:
1. Verify AWS CLI and credentials
2. Create/configure security group (`dstack-sg`) with ports 22, 80, 443, 3306
3. Launch EC2 instance with user-data running `ec2-setup.sh`
4. Wait for instance to be running
5. Output instance ID, public IP, and next steps

### 4. Wait for Bootstrap

The instance runs `ec2-setup.sh` on first boot via cloud-init. This takes 2-3 minutes.

Monitor progress:
```bash
# SSH into instance
ssh -i ~/.ssh/your-key.pem ubuntu@<PUBLIC_IP>

# Watch bootstrap log
tail -f /var/log/dstack-bootstrap.log
# Or cloud-init log
tail -f /var/log/cloud-init-output.log
```

### 5. Access the Dashboard

Once bootstrap completes:
- **HTTP**: `http://<PUBLIC_IP>:5000`
- **HTTPS** (if DOMAIN configured): `https://<DOMAIN>`
- **phpMyAdmin**: `http://<PUBLIC_IP>:8080`

## Deploying to Existing EC2/RDS

If you already have an EC2 instance and RDS database running, you can skip provisioning and bootstrap directly:

```bash
# Auto-detect instance by tag (default: dstack-prod)
bash cloud/provision-ec2.sh --existing

# Or specify the IP directly
bash cloud/provision-ec2.sh --existing --ip <YOUR_EC2_PUBLIC_IP>

# Or specify a custom tag
bash cloud/provision-ec2.sh --existing --tag my-custom-tag
```

This will:
1. Load configuration from `cloud/config.env`
2. Find the existing running EC2 instance
3. Run the DStack bootstrap script on the instance via SSH
4. Install Docker, clone the repo, configure RDS, and start services

### Prerequisites for existing EC2

- The EC2 instance must be **running** and accessible via SSH
- Security group must allow SSH (port 22) from your IP
- The instance must be tagged with `Name=dstack-prod` (or your custom `INSTANCE_NAME_TAG`)
- RDS must already exist and be accessible from the EC2 instance

### After bootstrap

Continue with the remaining steps:
1. Monitor bootstrap: `ssh -i ~/.ssh/your-key.pem ubuntu@<IP> 'tail -f /var/log/dstack-bootstrap.log'`
2. Verify containers: `docker compose ps`
3. Create database on RDS (if not exists)
4. Deploy your application

## RDS Security Group Configuration

The provisioning script creates a security group (`dstack-sg`) that allows:
- SSH (22) from anywhere (restrict in production!)
- HTTP (80) from anywhere
- HTTPS (443) from anywhere
- MySQL (3306) **from the security group itself** (self-referencing)

### For RDS Access

You have two options:

**Option A: RDS in Same VPC, Allow from EC2 SG (Recommended)**
1. Note the EC2 security group ID from the script output (e.g., `sg-xxxxxxxxx`)
2. Edit your RDS security group inbound rules:
   - Type: MySQL/Aurora (3306)
   - Source: `sg-xxxxxxxxx` (the EC2 security group ID)
3. This allows the EC2 instance to connect to RDS directly

**Option B: SSH Tunnel (For RDS in Private Subnet / Different VPC)**
The script outputs an SSH tunnel command:
```bash
ssh -i ~/.ssh/your-key.pem -L 3306:<RDS_ENDPOINT>:3306 ubuntu@<PUBLIC_IP>
```
Then connect your local DB client to `localhost:3306`.

## Let's Encrypt SSL

If you set `DOMAIN` and `EMAIL_FOR_LETSENCRYPT` in `config.env`:
1. The bootstrap script stops nginx temporarily
2. Runs `certbot --standalone` to obtain certificates
3. Copies certs to `docker/ssl/`
4. Restarts nginx with SSL
5. Sets up daily auto-renewal cron job at 3 AM

**DNS Requirement**: Your domain's A record must point to the EC2 public IP **before** running the script, or certbot will fail.

## Troubleshooting

### Instance Fails to Launch
- Check AWS CLI credentials: `aws sts get-caller-identity`
- Verify key pair exists in the region
- Check service quotas (EC2 instances, VPC, etc.)

### Bootstrap Fails
```bash
# SSH and check logs
ssh -i ~/.ssh/your-key.pem ubuntu@<PUBLIC_IP>
cat /var/log/dstack-bootstrap.log
cat /var/log/cloud-init-output.log
```

### Docker Services Not Starting
```bash
cd /opt/dstack/docker
docker compose logs -f
docker compose ps
```

### Let's Encrypt Fails
- Ensure DNS A record points to EC2 public IP
- Check port 80 is open in security group
- Verify email format is valid
- Check certbot logs: `/var/log/letsencrypt/letsencrypt.log`

### RDS Connection Fails
- Verify RDS security group allows inbound 3306 from EC2 SG
- Check RDS is in same VPC or VPC peering is configured
- Test from EC2: `mysql -h <RDS_ENDPOINT> -u <USER> -p`

## Cleanup

To terminate the instance and clean up:
```bash
# Get instance ID from script output or AWS console
aws ec2 terminate-instances --instance-ids i-xxxxxxxxx --region us-east-1

# Delete security group (after instance terminated)
aws ec2 delete-security-group --group-id sg-xxxxxxxxx --region us-east-1
```

## Cost Considerations

| Resource | Free Tier (12 months) | After Free Tier |
|----------|----------------------|-----------------|
| EC2 t3.micro | 750 hrs/month | ~$0.0104/hr |
| EC2 t3.small | NOT free tier | ~$0.0208/hr |
| RDS db.t3.micro | 750 hrs/month | ~$0.017/hr |
| EBS 20 GB | 30 GB/month | ~$0.10/GB/month |
| Data Transfer | 1 GB/month | ~$0.09/GB |

**Recommendation**: Use `t3.micro` for free tier, `t3.small` for production workloads.

## Security Notes

1. **Restrict SSH Access**: In production, change the security group rule for port 22 to your IP only (`YOUR_IP/32`)
2. **Use IAM Roles**: For production, attach an IAM role to the EC2 instance instead of using access keys
3. **Secrets Management**: Consider AWS Secrets Manager for RDS passwords instead of config.env
4. **VPC**: Deploy in a private subnet with NAT Gateway for production
5. **Monitoring**: Enable CloudWatch logs and metrics

## Next Steps

After successful deployment:
1. Configure your DNS to point to the EC2 public IP
2. Set up monitoring/alerting (CloudWatch, Datadog, etc.)
3. Configure automated backups for RDS
4. Set up CI/CD pipeline for updates
5. Review [DStack Documentation](../README.md) for application usage

---

*This guide covers EC2 deployment only. For local development setup, see [LOCAL_DEVELOPMENT.md](../LOCAL_DEVELOPMENT.md). For full documentation, see [docs/](../docs/).*