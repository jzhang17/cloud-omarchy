#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "=== Starting Omarchy cloud setup at $(date) ==="

# Variables from Terraform templatefile
WG_PORT="${wireguard_port}"
WG_SERVER_IP="${wireguard_server_ip}"
WG_CLIENT_IP="${wireguard_client_ip}"
WG_SUBNET="${wireguard_subnet}"

# Default user on Arch Linux AMI
DEFAULT_USER="arch"
USER_HOME="/home/$DEFAULT_USER"

# ============================================
# PART 1: System Updates and Base Packages
# ============================================
echo "=== Updating system and installing base packages ==="

# Initialize pacman keyring
pacman-key --init
pacman-key --populate archlinux

# Update system
pacman -Syu --noconfirm

# Install base packages first (needed for AUR)
pacman -S --noconfirm --needed \
    base-devel \
    git \
    wget \
    curl \
    vim \
    wireguard-tools \
    qrencode \
    linux-headers \
    xorg-server-xvfb \
    xorg-xinput \
    xdotool \
    openbox \
    xterm \
    python-pip \
    python-evdev

# ============================================
# PART 2: Install yay (AUR helper)
# ============================================
echo "=== Installing yay AUR helper ==="

cd /tmp
sudo -u $DEFAULT_USER git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
sudo -u $DEFAULT_USER makepkg -si --noconfirm
cd /
rm -rf /tmp/yay-bin

# ============================================
# PART 3: Install SSM Agent from AUR
# ============================================
echo "=== Installing AWS SSM Agent ==="

sudo -u $DEFAULT_USER yay -S --noconfirm amazon-ssm-agent-bin
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ============================================
# PART 4: Install NVIDIA drivers
# ============================================
echo "=== Installing NVIDIA drivers ==="

# Install NVIDIA drivers (use dkms for compatibility)
pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings

# ============================================
# PART 5: WireGuard Server Configuration
# ============================================
echo "=== Configuring WireGuard server ==="

WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

# Generate server keys
wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
chmod 600 "$WG_DIR/server_private.key"

SERVER_PRIVATE_KEY=$(cat "$WG_DIR/server_private.key")
SERVER_PUBLIC_KEY=$(cat "$WG_DIR/server_public.key")

# Generate client keys
wg genkey | tee "$WG_DIR/client_private.key" | wg pubkey > "$WG_DIR/client_public.key"
chmod 600 "$WG_DIR/client_private.key"

CLIENT_PRIVATE_KEY=$(cat "$WG_DIR/client_private.key")
CLIENT_PUBLIC_KEY=$(cat "$WG_DIR/client_public.key")

# Get the server's public IP
SERVER_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Determine the primary network interface
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Primary network interface: $PRIMARY_IFACE"

# Create server config
cat > "$WG_DIR/wg0.conf" << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $PRIMARY_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $PRIMARY_IFACE -j MASQUERADE

[Peer]
# macOS Client
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $WG_CLIENT_IP/32
EOF

chmod 600 "$WG_DIR/wg0.conf"

# ============================================
# PART 6: Client Configuration
# ============================================
echo "=== Generating client config ==="

CLIENT_CONFIG="$USER_HOME/wg0-client.conf"
cat > "$CLIENT_CONFIG" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $WG_CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_PUBLIC_IP:$WG_PORT
AllowedIPs = $WG_SERVER_IP/32
PersistentKeepalive = 25
EOF

chown $DEFAULT_USER:$DEFAULT_USER "$CLIENT_CONFIG"
chmod 600 "$CLIENT_CONFIG"

# ============================================
# PART 7: Enable IP Forwarding and Start WireGuard
# ============================================
echo "=== Enabling IP forwarding ==="

cat > /etc/sysctl.d/99-wireguard.conf << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
EOF

sysctl -p /etc/sysctl.d/99-wireguard.conf

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# ============================================
# PART 8: Install Sunshine for Streaming
# ============================================
echo "=== Installing Sunshine streaming server ==="

sudo -u $DEFAULT_USER yay -S --noconfirm sunshine

# Set capabilities for Sunshine
setcap cap_sys_admin+p $(which sunshine) || true

# Create systemd service for sunshine (runs as arch user)
cat > /etc/systemd/system/sunshine.service << EOF
[Unit]
Description=Sunshine Streaming Server
After=network.target

[Service]
Type=simple
User=$DEFAULT_USER
ExecStart=/usr/bin/sunshine
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sunshine

# ============================================
# PART 9: Configure Sunshine for X11 streaming
# ============================================
echo "=== Configuring Sunshine for X11 capture ==="

# Create Sunshine config directory
SUNSHINE_CONFIG_DIR="$USER_HOME/.config/sunshine"
mkdir -p "$SUNSHINE_CONFIG_DIR"

# Create Sunshine config optimized for Xvfb
cat > "$SUNSHINE_CONFIG_DIR/sunshine.conf" << 'EOF'
min_log_level = 0
capture = x11
output_name = 0
keyboard = enabled
mouse = enabled
EOF

chown -R $DEFAULT_USER:$DEFAULT_USER "$SUNSHINE_CONFIG_DIR"

# ============================================
# PART 10: Create Input Forwarder Script
# ============================================
echo "=== Creating input forwarder for Xvfb ==="

# Input forwarder bridges Sunshine's uinput devices to X11 via xdotool
cat > /usr/local/bin/input-forwarder << 'INPUTEOF'
#!/usr/bin/env python3
"""
Input Forwarder: Bridges Sunshine's uinput mouse/keyboard to X11 via xdotool.
Required because Xvfb doesn't read from uinput devices directly.
"""
import evdev
import subprocess
import os
import sys

os.environ["DISPLAY"] = ":0"

def find_sunshine_mouse():
    """Find Sunshine's mouse passthrough device."""
    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
    for dev in devices:
        if "Mouse passthrough" in dev.name and "absolute" not in dev.name:
            return dev
    return None

def main():
    mouse_dev = find_sunshine_mouse()
    if not mouse_dev:
        print("Waiting for Sunshine mouse device...", file=sys.stderr)
        import time
        for _ in range(30):
            time.sleep(1)
            mouse_dev = find_sunshine_mouse()
            if mouse_dev:
                break
        if not mouse_dev:
            print("No Sunshine mouse found after 30s", file=sys.stderr)
            sys.exit(1)

    print(f"Forwarding: {mouse_dev.name}", file=sys.stderr, flush=True)

    for event in mouse_dev.read_loop():
        if event.type == evdev.ecodes.EV_REL:
            if event.code == evdev.ecodes.REL_X:
                subprocess.run(["xdotool", "mousemove_relative", "--", str(event.value), "0"],
                             capture_output=True)
            elif event.code == evdev.ecodes.REL_Y:
                subprocess.run(["xdotool", "mousemove_relative", "--", "0", str(event.value)],
                             capture_output=True)
        elif event.type == evdev.ecodes.EV_KEY:
            btn = None
            if event.code == evdev.ecodes.BTN_LEFT:
                btn = "1"
            elif event.code == evdev.ecodes.BTN_RIGHT:
                btn = "3"
            elif event.code == evdev.ecodes.BTN_MIDDLE:
                btn = "2"
            if btn:
                cmd = "mousedown" if event.value else "mouseup"
                subprocess.run(["xdotool", cmd, btn], capture_output=True)

if __name__ == "__main__":
    main()
INPUTEOF

chmod +x /usr/local/bin/input-forwarder

# ============================================
# PART 11: Set up uinput permissions
# ============================================
echo "=== Setting up uinput permissions ==="

# Add arch user to input group
usermod -aG input,video $DEFAULT_USER

# Create udev rule for uinput permissions
cat > /etc/udev/rules.d/99-uinput.rules << 'EOF'
KERNEL=="uinput", MODE="0666", GROUP="input"
EOF

# Load uinput module on boot
echo "uinput" > /etc/modules-load.d/uinput.conf

# ============================================
# PART 12: Setup Omarchy installer
# ============================================
echo "=== Setting up Omarchy installer ==="

cat > "$USER_HOME/install-omarchy.sh" << 'OMARCHY_SCRIPT'
#!/bin/bash
set -e

echo "Installing Omarchy..."

# Run the Omarchy bare installer (without extra apps)
wget -qO- https://omarchy.org/install-bare | bash

touch "$HOME/.omarchy-installed"
echo "Omarchy installation complete!"
OMARCHY_SCRIPT

chmod +x "$USER_HOME/install-omarchy.sh"
chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME/install-omarchy.sh"

# ============================================
# PART 10: Summary
# ============================================
echo ""
echo "=========================================="
echo "Omarchy Cloud Setup Complete!"
echo "=========================================="
echo ""
echo "Server Public IP: $SERVER_PUBLIC_IP"
echo "WireGuard Port: $WG_PORT"
echo ""
echo "Next steps:"
echo "1. Connect via SSM: aws ssm start-session --target <instance-id>"
echo "2. Install Omarchy: ~/install-omarchy.sh"
echo ""
echo "WireGuard config: $USER_HOME/wg0-client.conf"
echo ""
echo "=========================================="

cat > "$USER_HOME/cloud-omarchy-info.txt" << EOF
Omarchy Cloud Streaming Setup
==============================
Server Public IP: $SERVER_PUBLIC_IP
WireGuard Port: $WG_PORT

VPN Network:
  Server IP: $WG_SERVER_IP
  Client IP: $WG_CLIENT_IP

Setup Steps:
1. Connect via SSM
2. Run ~/install-omarchy.sh to install Omarchy
3. Connect with Moonlight to $WG_SERVER_IP
EOF

chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME/cloud-omarchy-info.txt"

echo "=== user_data.sh completed at $(date) ==="
