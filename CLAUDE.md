# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Terraform project for deploying a GPU Linux streaming workstation on AWS with WireGuard VPN. Designed for streaming a desktop environment (Omarchy) via Sunshine/Moonlight over a secure VPN tunnel.

## Quick Start

```bash
./up.sh       # Start instance (~30-60 sec)
./down.sh     # Stop instance (~30 sec) - stops compute billing
./status.sh   # Check state and billing
./connect.sh  # SSM session to instance
```

## Commands

### Daily Operations (Fast)
```bash
# Start a stopped instance (or deploy if none exists)
./up.sh

# Stop instance - stops compute billing immediately (~30 sec)
./down.sh

# Check instance state and billing
./status.sh

# Connect via SSM
./connect.sh
```

### Destructive Operations
```bash
# Terminate instance completely (slow, ~5 min)
DESTROY=true ./down.sh

# Delete everything including data volume
TF_VAR_delete_data_volume=true ./down.sh

# Create EBS snapshot backup
./backup.sh
```

### Direct Terraform (rarely needed)
```bash
terraform init
terraform plan -var="my_ip=$(curl -s https://api.ipify.org)"
terraform apply -auto-approve
terraform destroy -auto-approve
```

## Billing

| State | Compute | Storage | Total |
|-------|---------|---------|-------|
| Running | ~$0.53/hr | ~$19/mo | ~$0.55/hr |
| Stopped | $0 | ~$19/mo | ~$19/mo |
| Destroyed | $0 | $0* | $0 |

*Data volume preserved unless `TF_VAR_delete_data_volume=true`

## Architecture

**Infrastructure (us-west-2):**
- EC2 g4dn.xlarge (4 vCPU, 16GB RAM, T4 GPU)
- 40GB gp3 root volume
- 200GB gp3 data volume (persistent)
- Security group: SSH from deployer IP, WireGuard UDP 51820 from anywhere

**Data Persistence:**
- Data volume mounted at `/mnt/data`
- `/home/ubuntu` bind-mounted from `/mnt/data/home`
- Survives instance stop/start and rebuilds

**Networking:**
- WireGuard VPN server auto-configured on boot
- Client config at `/home/ubuntu/wg0-client.conf`
- Streaming ports only accessible via VPN tunnel
- Public IP changes on each start - update WireGuard client config

## File Structure

| File | Purpose |
|------|---------|
| `main.tf` | AWS provider, EC2, security group, EBS resources |
| `variables.tf` | Input variables (region, instance type, etc.) |
| `outputs.tf` | Terraform outputs |
| `user_data.sh` | Cloud-init: volume setup, WireGuard, fstab |
| `up.sh` | Start or deploy instance |
| `down.sh` | Stop or destroy instance |
| `status.sh` | Show instance state and billing |
| `connect.sh` | SSM session helper |
| `backup.sh` | Create EBS snapshot |
| `auto-deploy.sh` | Quota polling deployment (for new accounts) |

## Streaming Setup (TODO)

Once instance is running:
1. Connect WireGuard on your laptop
2. SSH/SSM to instance and install Sunshine
3. Configure Sunshine streaming server
4. Connect with Moonlight client to VPN IP (10.200.200.1)

## Roadmap

- [ ] Auto-install Sunshine streaming server
- [ ] Auto-install Omarchy desktop environment
- [ ] One-click deployment script
- [ ] Elastic IP for stable WireGuard endpoint
