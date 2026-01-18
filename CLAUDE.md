# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omarchy Cloud - A GPU-accelerated Linux streaming workstation on AWS. Stream a full Arch Linux desktop (Omarchy/Hyprland) to your Mac via Moonlight over WireGuard VPN.

## Quick Start

```bash
# First time deployment
./auto-deploy.sh      # Creates instance, waits for setup

# Daily workflow
./start.sh            # Start stopped instance
./vpn.sh up           # Connect VPN
./stream.sh           # Start streaming services
# Open Moonlight → Add PC → 10.200.200.1

# When done
./stop.sh             # Stop instance (saves money, preserves data)
```

## Commands Reference

### Instance Management

| Command | Description |
|---------|-------------|
| `./auto-deploy.sh` | Deploy new instance with GPU quota polling |
| `./start.sh` | Start a stopped instance |
| `./stop.sh` | Stop instance (compute billing stops, storage continues) |
| `./destroy.sh` | Permanently delete instance and optionally cleanup IAM/SG |
| `./status.sh` | Show instance status, billing info, available commands |

### Streaming & Connection

| Command | Description |
|---------|-------------|
| `./vpn.sh up` | Connect to WireGuard VPN |
| `./vpn.sh down` | Disconnect VPN |
| `./vpn.sh status` | Show VPN connection status |
| `./stream.sh` | Start Xvfb + Sunshine streaming |
| `./stream.sh stop` | Stop streaming services |
| `./stream.sh status` | Check streaming service status |
| `./connect.sh` | SSM shell into instance |
| `./connect.sh wg` | Fetch WireGuard config from instance |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS (us-west-2)                       │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              EC2 g4dn.xlarge (Tesla T4)             │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │    │
│  │  │    Xvfb     │  │  Sunshine   │  │  WireGuard │  │    │
│  │  │  (Display)  │→ │ (Streaming) │  │   Server   │  │    │
│  │  └─────────────┘  └─────────────┘  └────────────┘  │    │
│  │         ↓              ↓                 ↑         │    │
│  │  ┌─────────────────────────────────────────────┐   │    │
│  │  │          NVENC Hardware Encoding            │   │    │
│  │  └─────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────┘    │
│                            │ UDP 51820                       │
└────────────────────────────│─────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │   WireGuard VPN  │
                    │   10.200.200.0/24│
                    └────────┬────────┘
                             │
┌────────────────────────────│─────────────────────────────────┐
│  Mac (Client)              │                                 │
│  ┌─────────────────────────▼─────────────────────────────┐  │
│  │                    Moonlight                          │  │
│  │              (connects to 10.200.200.1)               │  │
│  └───────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

**Components:**
- **EC2 g4dn.xlarge**: NVIDIA Tesla T4 GPU for hardware encoding
- **Xvfb**: Virtual framebuffer for headless display
- **Sunshine**: Game streaming server (NVENC encoding)
- **WireGuard**: Secure VPN tunnel for streaming traffic
- **Moonlight**: Client app on Mac for receiving stream

## File Structure

| File | Purpose |
|------|---------|
| `auto-deploy.sh` | Full deployment with quota polling |
| `start.sh` | Start stopped instance |
| `stop.sh` | Stop running instance |
| `destroy.sh` | Terminate instance and cleanup |
| `status.sh` | Show status and billing info |
| `vpn.sh` | Manage WireGuard VPN on Mac |
| `stream.sh` | Start/stop streaming services |
| `connect.sh` | SSM shell connection |
| `user_data.sh` | Cloud-init script (runs on first boot) |
| `wg0-client.conf` | WireGuard client config (generated) |
| `variables.tf` | Terraform variables (for reference) |
| `main.tf` | Terraform resources (for reference) |

## Billing

| State | Compute | Storage | Total |
|-------|---------|---------|-------|
| Running | ~$0.526/hr | ~$16/mo | ~$0.55/hr |
| Stopped | $0 | ~$16/mo | ~$16/mo |
| Terminated | $0 | $0 | $0 |

**Cost optimization:**
- Stop the instance when not in use (`./stop.sh`)
- Storage charges continue while stopped (~$16/mo for 200GB gp3)
- Destroy completely to stop all charges (`./destroy.sh`)

## First-Time Setup

### Prerequisites

```bash
# Install required tools
brew install awscli wireguard-tools jq

# Install Moonlight (if not already)
brew install --cask moonlight

# Configure AWS CLI
aws configure
```

### GPU Quota

You need GPU quota in us-west-2. Check your current quota:

```bash
aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --region us-west-2 \
    --query 'Quota.Value'
```

If it's 0, request an increase to 4 vCPUs via the AWS Console or CLI.

### Deploy

```bash
./auto-deploy.sh
```

This will:
1. Wait for GPU quota if needed
2. Create security group and IAM role
3. Launch Arch Linux instance with 200GB volume
4. Install NVIDIA drivers, WireGuard, Sunshine
5. Generate WireGuard client config

## Streaming Workflow

### Connect to Stream

```bash
# 1. Start the instance
./start.sh

# 2. Connect VPN
./vpn.sh up

# 3. Start streaming services
./stream.sh

# 4. Open Moonlight
#    Add PC → 10.200.200.1
#    First time: Accept cert, enter PIN from https://10.200.200.1:47990
```

### Disconnect

```bash
# Stop streaming (optional, happens on instance stop)
./stream.sh stop

# Disconnect VPN
./vpn.sh down

# Stop instance to save money
./stop.sh
```

## Troubleshooting

### X Server Crashes

The NVIDIA EGL libraries can conflict with Xvfb. The `stream.sh` script handles this by disabling the nvidia_gbm.json platform file.

### SSM Connection Issues

Check SSM agent status:
```bash
./status.sh  # Shows SSM Agent status
```

If offline, wait a minute after instance start or reboot the instance.

### Moonlight Can't Connect

1. Verify VPN is connected: `./vpn.sh status`
2. Verify streaming is running: `./stream.sh status`
3. Check Sunshine ports are listening (should show 47984, 47989, 47990, 48010)

### WireGuard Config Outdated

The instance gets a new public IP on each start. The `start.sh` script updates `wg0-client.conf` automatically, but you may need to:

```bash
./vpn.sh down
./vpn.sh up  # Will install updated config
```

## Notes

- Uses AWS CLI deployment (not Terraform) due to ARM64 Mac compatibility issues
- Instance name tag: `omarchy-cloud`
- Region: `us-west-2`
- VPN network: `10.200.200.0/24`
- Sunshine web UI: `https://10.200.200.1:47990`
