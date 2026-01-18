# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Terraform project for deploying an Omarchy (Arch Linux + Hyprland) GPU streaming workstation on AWS. Stream your desktop via Sunshine/Moonlight over a WireGuard VPN tunnel.

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
| Destroyed | $0 | $0 | $0 |

## Architecture

**Infrastructure (us-west-2):**
- EC2 g4dn.xlarge (4 vCPU, 16GB RAM, T4 GPU)
- 200GB gp3 root volume
- Arch Linux with NVIDIA drivers
- Security group: SSH from deployer IP, WireGuard UDP 51820 from anywhere

**Software Stack:**
- Omarchy (DHH's Arch Linux + Hyprland setup)
- Sunshine streaming server
- WireGuard VPN server

**Networking:**
- WireGuard VPN server auto-configured on boot
- Client config at `/home/arch/wg0-client.conf`
- Streaming ports only accessible via VPN tunnel
- Public IP changes on each start - update WireGuard client config

## File Structure

| File | Purpose |
|------|---------|
| `main.tf` | AWS provider, EC2, security group, EBS resources |
| `variables.tf` | Input variables (region, instance type, etc.) |
| `outputs.tf` | Terraform outputs |
| `user_data.sh` | Cloud-init: Arch packages, WireGuard, Sunshine, Hyprland |
| `up.sh` | Start or deploy instance |
| `down.sh` | Stop or destroy instance |
| `status.sh` | Show instance state and billing |
| `connect.sh` | SSM session helper |
| `backup.sh` | Create EBS snapshot |

## First-Time Setup

After deploying with `./up.sh`:

1. Connect to instance: `./connect.sh`
2. Install Omarchy: `~/install-omarchy.sh`
3. Start streaming: `~/start-streaming.sh`

On your laptop:
1. Fetch WireGuard config: `./connect.sh wg`
2. Import config to WireGuard client
3. Connect with Moonlight to `10.200.200.1`
