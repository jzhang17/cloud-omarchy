#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ACTION="${1:-status}"

show_usage() {
    echo "Usage: $0 [up|down|status]"
    echo ""
    echo "Commands:"
    echo "  up      - Connect to VPN"
    echo "  down    - Disconnect from VPN"
    echo "  status  - Show VPN status (default)"
    echo ""
}

check_wireguard() {
    if ! command -v wg &> /dev/null; then
        echo "ERROR: WireGuard tools not installed"
        echo "Install with: brew install wireguard-tools"
        exit 1
    fi
}

setup_config() {
    if [ ! -f "wg0-client.conf" ]; then
        echo "ERROR: wg0-client.conf not found"
        echo "Run ./start.sh first to get the config from the instance."
        exit 1
    fi

    # Check if config is in /etc/wireguard
    if [ ! -f "/etc/wireguard/wg0.conf" ]; then
        echo "Setting up WireGuard config (requires sudo)..."
        sudo mkdir -p /etc/wireguard
        sudo cp wg0-client.conf /etc/wireguard/wg0.conf
        sudo chmod 600 /etc/wireguard/wg0.conf
        echo "Config installed to /etc/wireguard/wg0.conf"
    else
        # Check if config needs update
        if ! diff -q wg0-client.conf /etc/wireguard/wg0.conf > /dev/null 2>&1; then
            echo "Updating WireGuard config..."
            sudo cp wg0-client.conf /etc/wireguard/wg0.conf
            sudo chmod 600 /etc/wireguard/wg0.conf
            echo "Config updated."
        fi
    fi
}

case "$ACTION" in
    up|connect)
        check_wireguard
        setup_config

        # Check if already connected
        if sudo wg show wg0 &> /dev/null 2>&1; then
            echo "VPN is already connected."
            echo ""
            sudo wg show wg0
            exit 0
        fi

        # Clean up any stale WireGuard state
        sudo wg-quick down wg0 2>/dev/null || true
        sudo rm -f /var/run/wireguard/wg0.name 2>/dev/null || true

        echo "Connecting to VPN..."
        sudo wg-quick up wg0
        echo ""
        echo "VPN connected!"
        echo "Server IP: 10.200.200.1"
        echo ""
        echo "Next: Open Moonlight and connect to 10.200.200.1"
        ;;

    down|disconnect)
        check_wireguard

        if ! sudo wg show wg0 &> /dev/null 2>&1; then
            echo "VPN is not connected."
            exit 0
        fi

        echo "Disconnecting VPN..."
        sudo wg-quick down wg0
        echo "VPN disconnected."
        ;;

    status|"")
        check_wireguard

        echo "=========================================="
        echo "VPN Status"
        echo "=========================================="
        echo ""

        if sudo wg show wg0 &> /dev/null 2>&1; then
            echo "Status: CONNECTED"
            echo ""
            sudo wg show wg0
        else
            echo "Status: DISCONNECTED"
            echo ""
            echo "To connect: ./vpn.sh up"
        fi
        ;;

    *)
        show_usage
        exit 1
        ;;
esac
