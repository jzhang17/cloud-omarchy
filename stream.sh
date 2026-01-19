#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

ACTION="${1:-start}"
MODE="${2:-hyprland}"  # hyprland (default) or x11

echo "=========================================="
echo "Omarchy Cloud - Streaming Services"
echo "=========================================="
echo ""

# Find instance by name tag
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
    echo "No running instance found."
    echo "Run ./start.sh first."
    exit 1
fi

echo "Instance: $INSTANCE_ID"
echo "Mode: $MODE"
echo ""

run_command() {
    local cmd="$1"
    local timeout="${2:-10}"
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"$cmd\"]" \
        --query 'Command.CommandId' \
        --output text)

    sleep "$timeout"
    aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || echo ""
}

start_hyprland() {
    echo "Starting Hyprland streaming (G5/vkms mode)..."
    echo ""

    # Step 1: Load vkms kernel module for virtual DRM display
    echo "Loading vkms module..."
    run_command "modprobe vkms 2>/dev/null || true" 2

    # Step 2: Set up permissions for DRM devices
    echo "Setting up permissions..."
    run_command "chmod 666 /dev/dri/card* 2>/dev/null || true; chmod 666 /dev/uinput 2>/dev/null || true" 2

    # Step 3: Kill any existing compositor/streaming processes
    echo "Cleaning up old processes..."
    run_command "pkill -9 hyprland 2>/dev/null || true; pkill -9 Hyprland 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true; pkill -9 foot 2>/dev/null || true" 2
    sleep 1

    # Step 4: Start seatd for seat management
    echo "Starting seatd..."
    run_command "systemctl start seatd 2>/dev/null || true; usermod -aG seat arch 2>/dev/null || true" 2

    # Step 5: Set up XDG runtime directory
    run_command "mkdir -p /run/user/1000; chown arch:arch /run/user/1000; chmod 700 /run/user/1000" 2

    # Step 6: Find vkms card (usually card1, but verify)
    echo "Finding vkms display..."
    VKMS_CARD=$(run_command "for card in /sys/class/drm/card*/device/driver; do if readlink \$card 2>/dev/null | grep -q vkms; then basename \$(dirname \$(dirname \$card)); break; fi; done" 3)
    VKMS_CARD=$(echo "$VKMS_CARD" | tr -d '[:space:]')
    if [ -z "$VKMS_CARD" ]; then
        VKMS_CARD="card1"  # Default fallback
    fi
    echo "  Using: /dev/dri/$VKMS_CARD"

    # Step 7: Start Hyprland with vkms
    echo "Starting Hyprland..."
    run_command "sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export LIBSEAT_BACKEND=seatd; export AQ_DRM_DEVICES=/dev/dri/$VKMS_CARD; nohup hyprland > /tmp/hyprland.log 2>&1 &'" 5

    # Step 8: Wait for Hyprland to start and configure monitor
    echo "Configuring display..."
    sleep 2
    run_command "sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; hyprctl keyword monitor Virtual-1,1920x1080@60,0x0,1 2>/dev/null || true'" 3

    # Step 9: Start a terminal so there's something to see
    echo "Starting terminal..."
    run_command "sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; hyprctl dispatch exec foot 2>/dev/null || true'" 2

    # Step 10: Ensure Sunshine config is set for Wayland
    echo "Configuring Sunshine for Wayland..."
    run_command "cp /home/arch/.config/sunshine/sunshine.conf /home/arch/.config/sunshine/sunshine.conf.bak 2>/dev/null || true; echo -e 'min_log_level = 0\ncapture = wlr\nencoder = nvenc\nkeyboard = enabled\nmouse = enabled' > /home/arch/.config/sunshine/sunshine.conf; chown arch:arch /home/arch/.config/sunshine/sunshine.conf" 2

    # Step 11: Find Wayland socket and start Sunshine
    echo "Starting Sunshine streaming server..."
    run_command "sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export WAYLAND_DISPLAY=wayland-1; nohup sunshine > /tmp/sunshine.log 2>&1 &'" 4

    # Step 12: Verify services
    verify_services "hyprland"
}

start_x11() {
    echo "Starting X11 streaming (Xvfb/Openbox fallback mode)..."
    echo ""

    # Step 1: Fix permissions for input devices
    echo "Setting up permissions..."
    run_command "chmod 666 /dev/uinput 2>/dev/null || true; chmod 666 /dev/dri/card0 2>/dev/null || true; usermod -aG input,video arch 2>/dev/null || true" 3

    # Step 2: Disable NVIDIA EGL GBM (causes X server crashes with Xvfb)
    run_command "mv /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json.disabled 2>/dev/null || true" 2

    # Step 3: Kill any existing X/Sunshine/WM/input-forwarder processes
    echo "Cleaning up old processes..."
    run_command "pkill -9 Xvfb 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true; pkill -9 openbox 2>/dev/null || true; pkill -f input-forwarder 2>/dev/null || true; pkill -f input_forward 2>/dev/null || true" 2
    sleep 1

    # Step 4: Set up XDG runtime directory
    run_command "mkdir -p /run/user/1000; chown arch:arch /run/user/1000; chmod 700 /run/user/1000" 2

    # Step 5: Start Xvfb with XTEST extension
    echo "Starting virtual display (Xvfb)..."
    run_command "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json Xvfb :0 -screen 0 1920x1080x24 +extension XTEST &" 3

    # Step 6: Start window manager (so there's something to see)
    echo "Starting window manager..."
    run_command "sudo -u arch bash -c 'export DISPLAY=:0; openbox &' 2>/dev/null || true" 2

    # Step 7: Start a terminal
    run_command "sudo -u arch bash -c 'export DISPLAY=:0; xterm -geometry 100x30+50+50 &' 2>/dev/null || true" 2

    # Step 8: Ensure Sunshine config is correct for X11 capture
    echo "Configuring Sunshine for X11..."
    run_command "mkdir -p /home/arch/.config/sunshine; echo -e 'min_log_level = 0\ncapture = x11\noutput_name = 0\nkeyboard = enabled\nmouse = enabled' > /home/arch/.config/sunshine/sunshine.conf; chown -R arch:arch /home/arch/.config/sunshine" 2

    # Step 9: Start Sunshine with proper environment
    echo "Starting Sunshine streaming server..."
    run_command "sudo -u arch bash -c 'export DISPLAY=:0; export XDG_RUNTIME_DIR=/run/user/1000; sunshine > /tmp/sunshine.log 2>&1 &'" 4

    # Step 10: Start input forwarder (bridges Sunshine uinput to X11)
    echo "Starting input forwarder..."
    run_command "nohup /usr/local/bin/input-forwarder > /tmp/input-forwarder.log 2>&1 & disown; sleep 1; pgrep -f input-forwarder > /dev/null || nohup python3 /tmp/input_forward.py > /tmp/input-forwarder.log 2>&1 &" 3

    # Step 11: Verify services
    verify_services "x11"
}

verify_services() {
    local mode="$1"
    echo ""
    echo "Checking services..."
    sleep 2

    if [ "$mode" = "hyprland" ]; then
        HYPRLAND_STATUS=$(run_command "pgrep -x Hyprland > /dev/null && echo RUNNING || echo STOPPED" 2)
        SUNSHINE_STATUS=$(run_command "pgrep sunshine > /dev/null && echo RUNNING || echo STOPPED" 2)

        echo "  Hyprland:       $HYPRLAND_STATUS"
        echo "  Sunshine:       $SUNSHINE_STATUS"
        echo ""

        if [[ "$HYPRLAND_STATUS" == *"RUNNING"* ]] && [[ "$SUNSHINE_STATUS" == *"RUNNING"* ]]; then
            print_success
        else
            echo "WARNING: Some services may not be running correctly."
            echo "Check logs: ./stream.sh logs"
        fi
    else
        XVFB_STATUS=$(run_command "pgrep Xvfb > /dev/null && echo RUNNING || echo STOPPED" 2)
        SUNSHINE_STATUS=$(run_command "pgrep sunshine > /dev/null && echo RUNNING || echo STOPPED" 2)
        OPENBOX_STATUS=$(run_command "pgrep openbox > /dev/null && echo RUNNING || echo STOPPED" 2)
        INPUT_STATUS=$(run_command "pgrep -f 'input-forwarder|input_forward' > /dev/null && echo RUNNING || echo STOPPED" 2)

        echo "  Xvfb:           $XVFB_STATUS"
        echo "  Openbox:        $OPENBOX_STATUS"
        echo "  Sunshine:       $SUNSHINE_STATUS"
        echo "  Input Forwarder: $INPUT_STATUS"
        echo ""

        if [[ "$XVFB_STATUS" == *"RUNNING"* ]] && [[ "$SUNSHINE_STATUS" == *"RUNNING"* ]] && [[ "$INPUT_STATUS" == *"RUNNING"* ]]; then
            print_success
        else
            echo "WARNING: Some services may not be running correctly."
            echo "Check logs: ./stream.sh logs"
        fi
    fi
}

print_success() {
    echo "=========================================="
    echo "Streaming Ready!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Connect VPN: ./vpn.sh up"
    echo "  2. Open Moonlight on your Mac"
    echo "  3. Add PC: 10.200.200.1"
    echo "  4. First time only - pair with PIN:"
    echo "     Open https://10.200.200.1:47990 in browser"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check status: ./stream.sh status"
    echo "  - View logs: ./stream.sh logs"
    echo ""
}

stop_all() {
    echo "Stopping streaming services..."
    run_command "pkill -9 Hyprland 2>/dev/null || true; pkill -9 hyprland 2>/dev/null || true; pkill -f input-forwarder 2>/dev/null || true; pkill -f input_forward 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true; pkill -9 openbox 2>/dev/null || true; pkill -9 xterm 2>/dev/null || true; pkill -9 foot 2>/dev/null || true; pkill -9 Xvfb 2>/dev/null || true" 3
    echo "Services stopped."
}

show_status() {
    echo "Service status:"
    echo ""

    STATUS=$(run_command "echo '=== Processes ==='; ps aux | grep -E 'Xvfb|sunshine|openbox|Hyprland|hyprland|foot' | grep -v grep || echo 'No streaming processes'; echo ''; echo '=== Sunshine Ports ==='; ss -tlnp 2>/dev/null | grep sunshine || echo 'No ports listening'; echo ''; echo '=== DRM Devices ==='; ls -la /dev/dri/ 2>/dev/null || echo 'No DRI devices'; echo ''; echo '=== Wayland Sockets ==='; ls -la /run/user/1000/wayland-* 2>/dev/null || echo 'No Wayland sockets'" 5)
    echo "$STATUS"
}

show_logs() {
    echo "Recent logs:"
    echo ""
    echo "=== Sunshine ==="
    run_command "tail -30 /tmp/sunshine.log 2>/dev/null || echo 'No Sunshine logs'" 5
    echo ""
    echo "=== Hyprland ==="
    run_command "tail -20 /tmp/hyprland.log 2>/dev/null || echo 'No Hyprland logs'" 3
}

case "$ACTION" in
    start)
        if [ "$MODE" = "x11" ]; then
            start_x11
        else
            start_hyprland
        fi
        ;;

    stop)
        stop_all
        ;;

    status)
        show_status
        ;;

    logs)
        show_logs
        ;;

    *)
        echo "Usage: $0 [start|stop|status|logs] [hyprland|x11]"
        echo ""
        echo "Commands:"
        echo "  start   - Start streaming services (default)"
        echo "  stop    - Stop all streaming services"
        echo "  status  - Show service status and ports"
        echo "  logs    - Show recent logs"
        echo ""
        echo "Modes:"
        echo "  hyprland - Use Hyprland/Wayland with vkms (default, for G5)"
        echo "  x11      - Use Xvfb/Openbox with X11 (fallback)"
        echo ""
        echo "Examples:"
        echo "  ./stream.sh              # Start Hyprland streaming"
        echo "  ./stream.sh start x11    # Start X11 fallback mode"
        echo "  ./stream.sh stop         # Stop all services"
        ;;
esac
