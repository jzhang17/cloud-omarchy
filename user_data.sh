#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "=== Starting Omarchy cloud setup at $(date) ==="

# Variables from Terraform templatefile
DATA_DEVICE="${data_device}"
WG_PORT="${wireguard_port}"
WG_SERVER_IP="${wireguard_server_ip}"
WG_CLIENT_IP="${wireguard_client_ip}"
WG_SUBNET="${wireguard_subnet}"

# Default user on Arch Linux AMI
DEFAULT_USER="arch"
USER_HOME="/home/$DEFAULT_USER"

# Fallback device names (NVMe naming varies)
find_data_device() {
    local max_wait=120
    local waited=0

    while [ $waited -lt $max_wait ]; do
        for dev in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
            if [ -b "$dev" ]; then
                echo "$dev"
                return 0
            fi
        done
        echo "Waiting for data device to appear..." >&2
        sleep 5
        waited=$((waited + 5))
    done

    echo "ERROR: Data device not found after $${max_wait}s" >&2
    return 1
}

# ============================================
# PART 1: Data Volume Setup
# ============================================
echo "=== Setting up data volume ==="

DATA_DEVICE=$(find_data_device)
echo "Found data device: $DATA_DEVICE"

MOUNT_POINT="/mnt/data"
mkdir -p "$MOUNT_POINT"

# Check if device has a filesystem
if ! blkid "$DATA_DEVICE" | grep -q 'TYPE='; then
    echo "Data volume is empty, formatting as ext4..."
    mkfs.ext4 -L data-volume "$DATA_DEVICE"
fi

# Get UUID for fstab
DATA_UUID=$(blkid -s UUID -o value "$DATA_DEVICE")
echo "Data volume UUID: $DATA_UUID"

# Mount the data volume
if ! mountpoint -q "$MOUNT_POINT"; then
    mount "$DATA_DEVICE" "$MOUNT_POINT"
fi

# Create home directory on data volume if it doesn't exist
if [ ! -d "$MOUNT_POINT/home" ]; then
    echo "Creating /mnt/data/home directory..."
    mkdir -p "$MOUNT_POINT/home"
    if [ -d "$USER_HOME" ] && [ "$(ls -A $USER_HOME 2>/dev/null)" ]; then
        cp -a "$USER_HOME/." "$MOUNT_POINT/home/"
    fi
    chown -R $DEFAULT_USER:$DEFAULT_USER "$MOUNT_POINT/home"
fi

# Bind mount /mnt/data/home to /home/arch
echo "Setting up bind mount for $USER_HOME..."
if mountpoint -q "$USER_HOME"; then
    umount "$USER_HOME" || true
fi

mount --bind "$MOUNT_POINT/home" "$USER_HOME"
chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME"

# Update /etc/fstab
echo "Updating /etc/fstab..."
sed -i '\|/mnt/data|d' /etc/fstab
sed -i "\|$USER_HOME|d" /etc/fstab

cat >> /etc/fstab << EOF
# Persistent data volume
UUID=$DATA_UUID  /mnt/data  ext4  defaults,nofail  0  2
# Bind mount for arch home
/mnt/data/home  $USER_HOME  none  bind  0  0
EOF

# ============================================
# PART 2: System Updates and Base Packages
# ============================================
echo "=== Updating system and installing base packages ==="

# Initialize pacman keyring
pacman-key --init
pacman-key --populate archlinux

# Update system
pacman -Syu --noconfirm

# Install essential packages
pacman -S --noconfirm --needed \
    base-devel \
    git \
    wget \
    curl \
    vim \
    wireguard-tools \
    qrencode \
    nvidia \
    nvidia-utils \
    nvidia-settings \
    linux-headers \
    dkms

# Install SSM agent for AWS
echo "=== Installing AWS SSM Agent ==="
pacman -S --noconfirm --needed amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ============================================
# PART 3: WireGuard Server Configuration
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
# PART 4: Client Configuration
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

# Also save to the persistent data volume
cp "$CLIENT_CONFIG" "$MOUNT_POINT/home/wg0-client.conf"
chown $DEFAULT_USER:$DEFAULT_USER "$MOUNT_POINT/home/wg0-client.conf"

# ============================================
# PART 5: Enable IP Forwarding and Start WireGuard
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
# PART 6: Install Omarchy
# ============================================
echo "=== Installing Omarchy ==="

# Create setup script for the arch user to run
cat > "$USER_HOME/install-omarchy.sh" << 'OMARCHY_SCRIPT'
#!/bin/bash
set -e

echo "Installing Omarchy..."

# Run the Omarchy bare installer (without extra apps)
# Using bare mode for cloud - no Spotify, OBS, etc.
wget -qO- https://omarchy.org/install-bare | bash

echo "Omarchy installation complete!"
OMARCHY_SCRIPT

chmod +x "$USER_HOME/install-omarchy.sh"
chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME/install-omarchy.sh"

# Run omarchy install as the arch user
# Note: This requires user interaction, so we'll set it up to run on first login
# or run it non-interactively if possible

# For now, create a first-login script
cat > "$USER_HOME/.bash_profile" << 'PROFILE'
# First login Omarchy setup
if [ ! -f "$HOME/.omarchy-installed" ]; then
    echo "=========================================="
    echo "Omarchy is ready to install!"
    echo "=========================================="
    echo ""
    echo "Run: ~/install-omarchy.sh"
    echo ""
    echo "Or for full install with apps:"
    echo "  wget -qO- https://omarchy.org/install | bash"
    echo ""
fi

# Source .bashrc if it exists
[[ -f ~/.bashrc ]] && . ~/.bashrc
PROFILE

chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME/.bash_profile"

# ============================================
# PART 7: Install Sunshine for Streaming
# ============================================
echo "=== Installing Sunshine streaming server ==="

# Install sunshine from AUR using yay
# First install yay if not present
if ! command -v yay &> /dev/null; then
    echo "Installing yay AUR helper..."
    cd /tmp
    sudo -u $DEFAULT_USER git clone https://aur.archlinux.org/yay.git
    cd yay
    sudo -u $DEFAULT_USER makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

# Install sunshine
sudo -u $DEFAULT_USER yay -S --noconfirm sunshine

# Configure sunshine for headless operation
mkdir -p /etc/sunshine
cat > /etc/sunshine/sunshine.conf << EOF
# Sunshine configuration for headless cloud streaming
origin_web_ui_allowed = wan
min_log_level = info
EOF

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
# PART 8: Configure Hyprland for Headless
# ============================================
echo "=== Setting up Hyprland headless configuration ==="

# Create Hyprland config directory
HYPRLAND_CONFIG="$USER_HOME/.config/hypr"
mkdir -p "$HYPRLAND_CONFIG"

# Create a headless Hyprland config
cat > "$HYPRLAND_CONFIG/hyprland-headless.conf" << 'HYPRCONF'
# Hyprland headless configuration for cloud streaming
# This creates a virtual display for Sunshine

# Create a headless monitor
monitor=HEADLESS-1,1920x1080@60,0x0,1

# Set wallpaper
exec-once = hyprpaper

# Start sunshine on launch
exec-once = sunshine

# Basic input config
input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
}

# General settings
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

# Decoration
decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    drop_shadow = yes
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(1a1a1aee)
}
HYPRCONF

chown -R $DEFAULT_USER:$DEFAULT_USER "$HYPRLAND_CONFIG"

# ============================================
# PART 9: Create startup script
# ============================================
echo "=== Creating startup scripts ==="

# Script to start headless streaming
cat > "$USER_HOME/start-streaming.sh" << 'STARTSCRIPT'
#!/bin/bash
# Start Hyprland in headless mode for streaming

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WAYLAND_DISPLAY=wayland-1

# Start Hyprland with headless config
Hyprland -c ~/.config/hypr/hyprland-headless.conf &

# Wait for Hyprland to start
sleep 3

# Create virtual display
hyprctl output create headless HEADLESS-1

echo "Headless streaming started!"
echo "Connect via Moonlight to: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
STARTSCRIPT

chmod +x "$USER_HOME/start-streaming.sh"
chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME/start-streaming.sh"

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
echo "1. Connect to instance: ./connect.sh"
echo "2. Install Omarchy: ~/install-omarchy.sh"
echo "3. Start streaming: ~/start-streaming.sh"
echo ""
echo "WireGuard config: $USER_HOME/wg0-client.conf"
echo ""
echo "=========================================="

# Save summary
cat > "$USER_HOME/cloud-omarchy-info.txt" << EOF
Omarchy Cloud Streaming Setup
==============================
Server Public IP: $SERVER_PUBLIC_IP
WireGuard Port: $WG_PORT

VPN Network:
  Server IP: $WG_SERVER_IP
  Client IP: $WG_CLIENT_IP

Setup Steps:
1. Connect via SSM or WireGuard
2. Run ~/install-omarchy.sh to install Omarchy
3. Run ~/start-streaming.sh to start headless streaming
4. Connect with Moonlight to $WG_SERVER_IP

Data Volume: $DATA_DEVICE mounted at $MOUNT_POINT
Home Directory: $USER_HOME (persistent)
EOF

chown $DEFAULT_USER:$DEFAULT_USER "$USER_HOME/cloud-omarchy-info.txt"
cp "$USER_HOME/cloud-omarchy-info.txt" "$MOUNT_POINT/home/"

echo "=== user_data.sh completed at $(date) ==="
