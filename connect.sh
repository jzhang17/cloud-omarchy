#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

STATE_FILE="$SCRIPT_DIR/.state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: No state file found at $STATE_FILE"
    echo "Run ./up.sh or ./auto-deploy.sh first to deploy the instance."
    exit 1
fi

INSTANCE_ID=$(jq -r '.instance_id' "$STATE_FILE")
REGION=$(jq -r '.region' "$STATE_FILE")
PUBLIC_IP=$(jq -r '.public_ip' "$STATE_FILE")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "null" ]; then
    echo "ERROR: No instance_id found in state file"
    exit 1
fi

echo "=========================================="
echo "GPU Streaming Workstation - Connect"
echo "=========================================="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Region: $REGION"
echo ""

# Check instance state
STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

echo "Instance State: $STATE"
echo ""

if [ "$STATE" != "running" ]; then
    echo "Instance is not running. Current state: $STATE"
    if [ "$STATE" == "stopped" ]; then
        echo ""
        echo "To start the instance:"
        echo "  aws ec2 start-instances --instance-ids $INSTANCE_ID --region $REGION"
    fi
    exit 1
fi

# Parse command line args
ACTION="${1:-ssh}"

case "$ACTION" in
    ssh|connect)
        echo "Connecting via SSM Session Manager..."
        echo ""
        aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
        ;;
    wg|wireguard)
        echo "Fetching WireGuard client config..."
        echo ""
        # Use SSM to cat the file
        aws ssm start-session \
            --target "$INSTANCE_ID" \
            --region "$REGION" \
            --document-name AWS-StartNonInteractiveCommand \
            --parameters '{"command":["cat /home/ubuntu/wg0-client.conf"]}' 2>/dev/null || \
        echo "Run: aws ssm start-session --target $INSTANCE_ID --region $REGION"
        echo "Then: cat /home/ubuntu/wg0-client.conf"
        ;;
    *)
        echo "Usage: $0 [ssh|wg]"
        echo ""
        echo "  ssh  - Connect to instance via SSM (default)"
        echo "  wg   - Fetch WireGuard client config"
        ;;
esac
