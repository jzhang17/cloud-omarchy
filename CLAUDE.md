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
./stream.sh           # Start Hyprland streaming
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
| `./stream.sh` | Start Hyprland + Sunshine (default, G5) |
| `./stream.sh start x11` | Start Xvfb + Openbox + Sunshine (fallback) |
| `./stream.sh stop` | Stop streaming services |
| `./stream.sh status` | Check streaming service status |
| `./stream.sh logs` | View recent Sunshine/Hyprland logs |
| `./connect.sh` | SSM shell into instance |
| `./connect.sh wg` | Fetch WireGuard config from instance |

## Architecture

### G5 Instance (Recommended - Hyprland/Wayland)

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS (us-west-2)                       │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              EC2 g5.xlarge (NVIDIA A10G)            │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │    │
│  │  │    vkms     │  │  Hyprland   │  │  Sunshine  │  │    │
│  │  │  (Virtual   │→ │  (Wayland   │→ │  (wlr      │  │    │
│  │  │   Display)  │  │  Compositor)│  │   capture) │  │    │
│  │  └─────────────┘  └─────────────┘  └────────────┘  │    │
│  │         ↓              ↓                 ↓         │    │
│  │  ┌─────────────────────────────────────────────┐   │    │
│  │  │          NVENC Hardware Encoding            │   │    │
│  │  └─────────────────────────────────────────────┘   │    │
│  │                                   ┌────────────┐   │    │
│  │                                   │  WireGuard │   │    │
│  │                                   │   Server   │   │    │
│  │                                   └────────────┘   │    │
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

**G5 Components:**
- **EC2 g5.xlarge**: NVIDIA A10G GPU with KMS support for native Wayland
- **vkms**: Virtual Kernel Mode Setting - creates a virtual DRM display with connectors for Hyprland
- **Hyprland**: Wayland compositor (Omarchy's default)
- **Sunshine (wlr capture)**: Game streaming server using Wayland protocol capture
- **WireGuard**: Secure VPN tunnel for streaming traffic
- **Moonlight**: Client app on Mac for receiving stream

**Why G5 over G4dn:**
- G4dn (Tesla T4) doesn't expose DRM connectors, so Hyprland can't find a display
- G5 (A10G) supports KMS and with vkms module provides virtual DRM connectors
- vkms creates a virtual display that Hyprland can use as its output

### X11 Fallback Mode

For G4dn instances or troubleshooting, an X11 fallback is available:

```bash
./stream.sh start x11  # Uses Xvfb + Openbox instead of Hyprland
```

This mode uses:
- **Xvfb**: Virtual framebuffer for headless X11 display
- **Openbox**: Lightweight X11 window manager
- **Sunshine (x11 capture)**: X11 screen capture
- **Input Forwarder**: Python script bridging Sunshine's uinput to X11

## File Structure

| File | Purpose |
|------|---------|
| `auto-deploy.sh` | Full deployment with quota polling |
| `start.sh` | Start stopped instance |
| `stop.sh` | Stop running instance |
| `destroy.sh` | Terminate instance and cleanup |
| `status.sh` | Show status and billing info |
| `vpn.sh` | Manage WireGuard VPN on Mac |
| `stream.sh` | Start/stop streaming services (Hyprland or X11) |
| `connect.sh` | SSM shell connection |
| `user_data.sh` | Cloud-init script (runs on first boot) |
| `wg0-client.conf` | WireGuard client config (generated) |
| `variables.tf` | Terraform variables (for reference) |
| `main.tf` | Terraform resources (for reference) |

## Billing

| State | Compute | Storage | Total |
|-------|---------|---------|-------|
| Running (g5.xlarge) | ~$1.01/hr | ~$16/mo | ~$1.03/hr |
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
4. Install NVIDIA drivers, WireGuard, Sunshine, Hyprland dependencies
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

### Hyprland Won't Start

**Symptom:** `./stream.sh` shows Hyprland as STOPPED

**Common causes:**
1. **seatd not running**: The seat management daemon must be running
2. **Wrong DRM device**: Hyprland needs to use the vkms device (usually card1)
3. **vkms not loaded**: The kernel module needs to be loaded

**Solution:**
```bash
./connect.sh  # SSM into instance
# Check vkms is loaded
lsmod | grep vkms
# If not loaded:
sudo modprobe vkms

# Check seatd
systemctl status seatd
# If not running:
sudo systemctl start seatd

# Restart streaming
exit
./stream.sh stop
./stream.sh start
```

### Mouse/Keyboard Not Working (Hyprland Mode)

**Symptom:** Video streams but input doesn't work.

**Solution:** Fully disconnect from Moonlight and reconnect:
1. Press Ctrl+Shift+Alt+Q (or your quit shortcut) to disconnect
2. Wait 3-5 seconds
3. Reconnect to 10.200.200.1

This re-establishes the control channel. Unlike X11 mode, Hyprland/Wayland handles input directly through Sunshine without needing an input forwarder.

### Mouse/Keyboard Not Working (X11 Mode)

**Symptom:** Video streams but mouse cursor doesn't move.

**Cause:** The input forwarder may not be running. Xvfb doesn't read from uinput devices directly.

**Solution:**
```bash
./stream.sh status  # Should show "Input Forwarder: RUNNING"
./stream.sh stop
./stream.sh start x11
```

### Black Screen in Stream

**Symptom:** Moonlight connects but shows black screen.

**For Hyprland:** Check that a terminal is running:
```bash
./connect.sh
hyprctl dispatch exec foot  # Start a terminal
```

**For X11:** Check that openbox and xterm are running:
```bash
./connect.sh
DISPLAY=:0 openbox &
DISPLAY=:0 xterm &
```

### Video Capture Error (503)

**Symptom:** Sunshine shows "Failed to initialize video capture" error.

**For Hyprland:**
- Make sure Hyprland started successfully: `./stream.sh status`
- Check Sunshine config has `capture = wlr`: `cat ~/.config/sunshine/sunshine.conf`

**For X11:**
- Make sure Xvfb is running
- Check Sunshine config has `capture = x11` and `output_name = 0`

**Solution:** Restart streaming:
```bash
./stream.sh stop
./stream.sh start  # or ./stream.sh start x11
```

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
4. Check logs: `./stream.sh logs`

### WireGuard Config Outdated

The instance gets a new public IP on each start. The `start.sh` script updates `wg0-client.conf` automatically, but you may need to:

```bash
./vpn.sh down
./vpn.sh up  # Will install updated config
```

## Technical Details

### Why vkms?

Datacenter GPUs like NVIDIA A10G are classified as "3D Controllers" rather than "VGA Controllers" and don't provide physical display connectors. Wayland compositors like Hyprland require DRM connectors to function.

The **vkms (Virtual Kernel Mode Setting)** kernel module creates a virtual DRM device with a connector (Virtual-1) that Hyprland can use as its output. Sunshine then captures the compositor's output via the Wayland protocol (wlr capture mode).

### Key Environment Variables for Hyprland

```bash
export XDG_RUNTIME_DIR=/run/user/1000
export LIBSEAT_BACKEND=seatd
export AQ_DRM_DEVICES=/dev/dri/card1  # Point to vkms device
```

### Key Environment Variables for Sunshine (Wayland)

```bash
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1
```

## Notes

- Uses AWS CLI deployment (not Terraform) due to ARM64 Mac compatibility issues
- Instance type: `g5.xlarge` (NVIDIA A10G GPU)
- Instance name tag: `omarchy-cloud`
- Region: `us-west-2`
- VPN network: `10.200.200.0/24`
- Sunshine web UI: `https://10.200.200.1:47990`
