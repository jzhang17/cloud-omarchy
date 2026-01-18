#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

ACTION="${1:-start}"

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

case "$ACTION" in
    start)
        echo "Starting streaming services..."
        echo ""

        # Step 1: Fix permissions for input devices
        echo "Setting up permissions..."
        run_command "chmod 666 /dev/uinput 2>/dev/null || true; chmod 666 /dev/dri/card0 2>/dev/null || true; usermod -aG input,video arch 2>/dev/null || true" 3

        # Step 2: Disable NVIDIA EGL GBM (causes X server crashes with Xvfb)
        run_command "mv /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json.disabled 2>/dev/null || true" 2

        # Step 3: Kill any existing X/Sunshine/WM processes
        echo "Cleaning up old processes..."
        run_command "pkill -9 Xvfb 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true; pkill -9 openbox 2>/dev/null || true" 2
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

        # Step 8: Start Sunshine with proper environment
        echo "Starting Sunshine streaming server..."
        run_command "sudo -u arch bash -c 'export DISPLAY=:0; export XDG_RUNTIME_DIR=/run/user/1000; sunshine > /tmp/sunshine.log 2>&1 &'" 4

        # Step 9: Verify services
        echo ""
        echo "Checking services..."
        sleep 2

        XVFB_STATUS=$(run_command "pgrep Xvfb > /dev/null && echo RUNNING || echo STOPPED" 2)
        SUNSHINE_STATUS=$(run_command "pgrep sunshine > /dev/null && echo RUNNING || echo STOPPED" 2)
        OPENBOX_STATUS=$(run_command "pgrep openbox > /dev/null && echo RUNNING || echo STOPPED" 2)

        echo "  Xvfb:     $XVFB_STATUS"
        echo "  Openbox:  $OPENBOX_STATUS"
        echo "  Sunshine: $SUNSHINE_STATUS"
        echo ""

        if [[ "$XVFB_STATUS" == *"RUNNING"* ]] && [[ "$SUNSHINE_STATUS" == *"RUNNING"* ]]; then
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
            echo "  - If mouse doesn't work: disconnect and reconnect in Moonlight"
            echo "  - Check status: ./stream.sh status"
            echo "  - View logs: ./stream.sh logs"
            echo ""
        else
            echo "WARNING: Some services may not be running correctly."
            echo "Check logs: ./stream.sh logs"
        fi
        ;;

    stop)
        echo "Stopping streaming services..."
        run_command "pkill -9 sunshine 2>/dev/null || true; pkill -9 openbox 2>/dev/null || true; pkill -9 xterm 2>/dev/null || true; pkill -9 Xvfb 2>/dev/null || true" 3
        echo "Services stopped."
        ;;

    status)
        echo "Service status:"
        echo ""

        STATUS=$(run_command "echo '=== Processes ==='; ps aux | grep -E 'Xvfb|sunshine|openbox' | grep -v grep || echo 'No streaming processes'; echo ''; echo '=== Sunshine Ports ==='; ss -tlnp 2>/dev/null | grep sunshine || echo 'No ports listening'; echo ''; echo '=== Input Devices ==='; ls -la /dev/uinput /dev/dri/card0 2>/dev/null || echo 'Device check failed'" 5)
        echo "$STATUS"
        ;;

    logs)
        echo "Recent Sunshine logs:"
        echo ""
        run_command "tail -50 /tmp/sunshine.log 2>/dev/null || journalctl -u sunshine --no-pager -n 50 2>/dev/null || echo 'No logs found'" 5
        ;;

    *)
        echo "Usage: $0 [start|stop|status|logs]"
        echo ""
        echo "Commands:"
        echo "  start   - Start Xvfb, Openbox, and Sunshine (default)"
        echo "  stop    - Stop all streaming services"
        echo "  status  - Show service status and ports"
        echo "  logs    - Show recent Sunshine logs"
        ;;
esac
