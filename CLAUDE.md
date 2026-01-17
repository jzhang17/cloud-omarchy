# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Terraform project for deploying a low-latency GPU Linux streaming workstation on AWS with WireGuard VPN.

## Commands

### Deployment
```bash
# Deploy (auto-detects public IP for SSH whitelist)
./up.sh

# Destroy instance but preserve data volume
./down.sh

# Destroy everything including data volume
TF_VAR_delete_data_volume=true ./down.sh

# Create EBS snapshot backup
./backup.sh
```

### Direct Terraform Commands
```bash
terraform init
terraform plan -var="my_ip=$(curl -s https://api.ipify.org)"
terraform apply
terraform destroy
```

## Architecture

**Infrastructure Components:**
- EC2 instance (g4dn.xlarge in us-west-1, Ubuntu 22.04) with GPU for streaming
- Persistent 200GB gp3 EBS data volume (separate from root, survives rebuilds)
- Security group: SSH from deployer IP only, WireGuard UDP 51820 from anywhere

**Data Persistence:**
- Data volume mounted at `/mnt/data`
- `/home/ubuntu` bind-mounted from `/mnt/data/home` for persistent home directory
- Volume attachment managed separately to allow instance replacement

**Networking:**
- WireGuard VPN server auto-configured via cloud-init
- Client config generated at `/home/ubuntu/wg0-client.conf`
- Streaming ports (Sunshine/Moonlight) accessible only via VPN tunnel

## File Structure

| File | Purpose |
|------|---------|
| `main.tf` | AWS provider, EC2, security group, EBS volume resources |
| `variables.tf` | Input variables with defaults |
| `outputs.tf` | Terraform outputs for scripts |
| `user_data.sh` | Cloud-init: volume setup, WireGuard config, fstab |
| `up.sh` / `down.sh` / `backup.sh` | Wrapper scripts for operations |
