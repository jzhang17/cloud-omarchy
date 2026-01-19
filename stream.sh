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

    # Step 3: Kill ALL existing compositor/streaming processes (prevent duplicates)
    echo "Cleaning up old processes..."
    run_command "pkill -9 hyprland 2>/dev/null || true; pkill -9 Hyprland 2>/dev/null || true; pkill -9 hyprland-welcome 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true; pkill -9 foot 2>/dev/null || true" 2
    sleep 2

    # Step 4: Clean up stale Hyprland runtime state (prevents multiple instance issues)
    echo "Cleaning up stale state..."
    run_command "rm -rf /run/user/1000/hypr 2>/dev/null || true; rm -f /run/user/1000/wayland-* 2>/dev/null || true" 2

    # Step 5: Restart seatd to clear any stuck clients
    echo "Restarting seatd..."
    run_command "systemctl restart seatd 2>/dev/null || true; usermod -aG seat arch 2>/dev/null || true" 3

    # Step 6: Set up XDG runtime directory
    run_command "mkdir -p /run/user/1000; chown arch:arch /run/user/1000; chmod 700 /run/user/1000" 2

    # Step 7: Find vkms card (usually card1, but verify)
    echo "Finding vkms display..."
    VKMS_CARD=$(run_command "for card in /sys/class/drm/card*/device/driver; do if readlink \$card 2>/dev/null | grep -q vkms; then basename \$(dirname \$(dirname \$card)); break; fi; done" 3)
    VKMS_CARD=$(echo "$VKMS_CARD" | tr -d '[:space:]')
    if [ -z "$VKMS_CARD" ]; then
        VKMS_CARD="card1"  # Default fallback
    fi
    echo "  Using: /dev/dri/$VKMS_CARD"

    # Step 8: Create Hyprland config with resolution BEFORE starting
    # Resolution must be set in config file to set DRM framebuffer size correctly
    # 2560x1600 = same 16:10 aspect ratio as MacBook Pro 14" (3024x1964)
    # Also set visible background color (default is nearly black 0xFF111111)
    echo "Creating Hyprland config (2560x1600)..."
    run_command "mkdir -p /home/arch/.config/hypr; echo 'monitor = Virtual-1, 2560x1600@60, 0x0, 1' > /home/arch/.config/hypr/hyprland.conf; echo 'misc { background_color = rgb(285577) }' >> /home/arch/.config/hypr/hyprland.conf; echo 'exec-once = foot' >> /home/arch/.config/hypr/hyprland.conf; chown -R arch:arch /home/arch/.config/hypr" 2

    # Step 9: Start Hyprland with vkms (single instance only)
    echo "Starting Hyprland..."
    run_command "sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export LIBSEAT_BACKEND=seatd; export AQ_DRM_DEVICES=/dev/dri/$VKMS_CARD; nohup hyprland > /tmp/hyprland.log 2>&1 &'" 5

    # Step 10: Wait and verify only one Hyprland is running
    echo "Verifying single instance..."
    HYPR_COUNT=$(run_command "pgrep -c hyprland 2>/dev/null || echo 0" 2)
    HYPR_COUNT=$(echo "$HYPR_COUNT" | tr -d '[:space:]')
    if [ "$HYPR_COUNT" -gt 2 ]; then
        echo "WARNING: Multiple Hyprland instances detected ($HYPR_COUNT). Cleaning up..."
        run_command "pkill -9 hyprland 2>/dev/null || true; pkill -9 Hyprland 2>/dev/null || true; sleep 2; sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export LIBSEAT_BACKEND=seatd; export AQ_DRM_DEVICES=/dev/dri/$VKMS_CARD; nohup hyprland > /tmp/hyprland.log 2>&1 &'" 5
    fi

    # Step 11: Ensure Sunshine config is set for wlr capture
    # Note: KMS capture doesn't work with vkms (empty monitor list)
    # wlr capture uses Wayland screencopy protocol and works with Hyprland
    # Unfortunately NVENC doesn't work with wlr (frames in CPU memory), so software encoding is used
    echo "Configuring Sunshine for wlr capture..."
    run_command "mkdir -p /home/arch/.config/sunshine; echo 'min_log_level = 0' > /home/arch/.config/sunshine/sunshine.conf; echo 'capture = wlr' >> /home/arch/.config/sunshine/sunshine.conf; echo 'encoder = software' >> /home/arch/.config/sunshine/sunshine.conf; echo 'keyboard = enabled' >> /home/arch/.config/sunshine/sunshine.conf; echo 'mouse = enabled' >> /home/arch/.config/sunshine/sunshine.conf; chown -R arch:arch /home/arch/.config/sunshine" 2

    # Step 12: Start Sunshine streaming server
    echo "Starting Sunshine streaming server..."
    run_command "sudo -u arch bash -c 'export XDG_RUNTIME_DIR=/run/user/1000; export WAYLAND_DISPLAY=wayland-1; nohup sunshine > /tmp/sunshine.log 2>&1 &'" 4

    # Step 13: Verify services
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
