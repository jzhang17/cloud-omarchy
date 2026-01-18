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
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"$cmd\"]" \
        --query 'Command.CommandId' \
        --output text)

    sleep 3
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

        # Disable NVIDIA EGL GBM (causes X server crashes)
        run_command "mv /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json.disabled 2>/dev/null || true"

        # Kill any existing X/Sunshine
        run_command "pkill -9 Xvfb 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true"
        sleep 2

        # Start Xvfb
        echo "Starting virtual display..."
        run_command "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json Xvfb :0 -screen 0 1920x1080x24 &"
        sleep 2

        # Start Sunshine
        echo "Starting Sunshine streaming server..."
        run_command "sudo -u arch bash -c 'export DISPLAY=:0; export XDG_RUNTIME_DIR=/run/user/1000; mkdir -p /run/user/1000; sunshine &'"
        sleep 3

        # Check status
        echo ""
        echo "Checking services..."
        XVFB_STATUS=$(run_command "pgrep Xvfb > /dev/null && echo RUNNING || echo STOPPED")
        SUNSHINE_STATUS=$(run_command "pgrep sunshine > /dev/null && echo RUNNING || echo STOPPED")

        echo "  Xvfb:     $XVFB_STATUS"
        echo "  Sunshine: $SUNSHINE_STATUS"
        echo ""

        if [[ "$XVFB_STATUS" == *"RUNNING"* ]] && [[ "$SUNSHINE_STATUS" == *"RUNNING"* ]]; then
            echo "=========================================="
            echo "Streaming Ready!"
            echo "=========================================="
            echo ""
            echo "1. Connect VPN (if not connected): ./vpn.sh up"
            echo "2. Open Moonlight"
            echo "3. Add PC: 10.200.200.1"
            echo "4. First time: Accept certificate and enter PIN from:"
            echo "   https://10.200.200.1:47990"
            echo ""
        else
            echo "WARNING: Some services may not be running correctly."
            echo "Try: ./stream.sh status"
        fi
        ;;

    stop)
        echo "Stopping streaming services..."
        run_command "pkill -9 Xvfb 2>/dev/null || true; pkill -9 sunshine 2>/dev/null || true"
        echo "Services stopped."
        ;;

    status)
        echo "Service status:"
        echo ""

        XVFB_STATUS=$(run_command "ps aux | grep Xvfb | grep -v grep || echo 'Xvfb: NOT RUNNING'")
        SUNSHINE_STATUS=$(run_command "ps aux | grep sunshine | grep -v grep || echo 'Sunshine: NOT RUNNING'")

        echo "$XVFB_STATUS"
        echo "$SUNSHINE_STATUS"
        echo ""

        # Check ports
        echo "Sunshine ports:"
        run_command "ss -tlnp | grep sunshine | head -5 || echo 'No ports listening'"
        ;;

    *)
        echo "Usage: $0 [start|stop|status]"
        echo ""
        echo "Commands:"
        echo "  start   - Start Xvfb and Sunshine (default)"
        echo "  stop    - Stop streaming services"
        echo "  status  - Show service status"
        ;;
esac
