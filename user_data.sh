#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "=== Starting user_data.sh at $(date) ==="

# Variables from Terraform templatefile
DATA_DEVICE="${data_device}"
WG_PORT="${wireguard_port}"
WG_SERVER_IP="${wireguard_server_ip}"
WG_CLIENT_IP="${wireguard_client_ip}"
WG_SUBNET="${wireguard_subnet}"

# Fallback device names (NVMe naming varies)
find_data_device() {
    # Wait for device to appear (EBS volume attachment can take time)
    local max_wait=120
    local waited=0

    while [ $waited -lt $max_wait ]; do
        # Try common device names
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

# Get UUID for fstab (more reliable than device name)
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
    # Copy existing ubuntu home if it has data
    if [ -d /home/ubuntu ] && [ "$(ls -A /home/ubuntu 2>/dev/null)" ]; then
        cp -a /home/ubuntu/. "$MOUNT_POINT/home/"
    fi
    chown -R ubuntu:ubuntu "$MOUNT_POINT/home"
fi

# Bind mount /mnt/data/home to /home/ubuntu
echo "Setting up bind mount for /home/ubuntu..."
if mountpoint -q /home/ubuntu; then
    umount /home/ubuntu || true
fi

mount --bind "$MOUNT_POINT/home" /home/ubuntu
chown ubuntu:ubuntu /home/ubuntu

# Update /etc/fstab
echo "Updating /etc/fstab..."

# Remove any existing entries for our mounts
sed -i '\|/mnt/data|d' /etc/fstab
sed -i '\|/home/ubuntu|d' /etc/fstab

# Add new entries
cat >> /etc/fstab << EOF
# Persistent data volume
UUID=$DATA_UUID  /mnt/data  ext4  defaults,nofail  0  2
# Bind mount for ubuntu home
/mnt/data/home  /home/ubuntu  none  bind  0  0
EOF

echo "fstab updated:"
cat /etc/fstab

# ============================================
# PART 2: System Updates and WireGuard Install
# ============================================
echo "=== Installing WireGuard ==="

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wireguard wireguard-tools qrencode

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

# Client config for macOS
CLIENT_CONFIG="/home/ubuntu/wg0-client.conf"
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

chown ubuntu:ubuntu "$CLIENT_CONFIG"
chmod 600 "$CLIENT_CONFIG"

# Also save to the persistent data volume
cp "$CLIENT_CONFIG" "$MOUNT_POINT/home/wg0-client.conf"
chown ubuntu:ubuntu "$MOUNT_POINT/home/wg0-client.conf"

# ============================================
# PART 5: Enable IP Forwarding and Start WireGuard
# ============================================
echo "=== Enabling IP forwarding ==="

# Enable IP forwarding
cat > /etc/sysctl.d/99-wireguard.conf << EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
EOF

sysctl -p /etc/sysctl.d/99-wireguard.conf

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# ============================================
# PART 6: Print Summary
# ============================================
echo ""
echo "=========================================="
echo "WireGuard Server Setup Complete!"
echo "=========================================="
echo ""
echo "Server Public IP: $SERVER_PUBLIC_IP"
echo "Server Public Key: $SERVER_PUBLIC_KEY"
echo "WireGuard Port: $WG_PORT"
echo ""
echo "VPN Network:"
echo "  Server IP: $WG_SERVER_IP"
echo "  Client IP: $WG_CLIENT_IP"
echo "  Subnet: $WG_SUBNET"
echo ""
echo "Client config saved to: /home/ubuntu/wg0-client.conf"
echo ""
echo "To retrieve client config, run:"
echo "  scp -i <key.pem> ubuntu@$SERVER_PUBLIC_IP:~/wg0-client.conf ."
echo ""
echo "=========================================="

# Save summary to a file for easy access
cat > /home/ubuntu/wireguard-info.txt << EOF
WireGuard Server Information
============================
Server Public IP: $SERVER_PUBLIC_IP
Server Public Key: $SERVER_PUBLIC_KEY
WireGuard Port: $WG_PORT

VPN Network:
  Server IP: $WG_SERVER_IP
  Client IP: $WG_CLIENT_IP
  Subnet: $WG_SUBNET

Client config: /home/ubuntu/wg0-client.conf

Data Volume: $DATA_DEVICE mounted at $MOUNT_POINT
Home Directory: /home/ubuntu (bind-mounted from $MOUNT_POINT/home)
EOF

chown ubuntu:ubuntu /home/ubuntu/wireguard-info.txt
cp /home/ubuntu/wireguard-info.txt "$MOUNT_POINT/home/"

echo "=== user_data.sh completed at $(date) ==="
