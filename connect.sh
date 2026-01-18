#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

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

# Get instance info
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "=========================================="
echo "Omarchy Cloud - Connect"
echo "=========================================="
echo ""
echo "Instance: $INSTANCE_ID"
echo "Region:   $REGION"
echo "IP:       $PUBLIC_IP"
echo ""

# Parse command line args
ACTION="${1:-ssh}"

case "$ACTION" in
    ssh|connect|"")
        echo "Connecting via SSM..."
        echo ""
        aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
        ;;
    wg|wireguard)
        echo "Fetching WireGuard client config..."
        echo ""
        CMD_ID=$(aws ssm send-command \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["cat /home/arch/wg0-client.conf"]' \
            --query 'Command.CommandId' \
            --output text)
        sleep 3
        aws ssm get-command-invocation \
            --region "$REGION" \
            --command-id "$CMD_ID" \
            --instance-id "$INSTANCE_ID" \
            --query 'StandardOutputContent' \
            --output text
        ;;
    *)
        echo "Usage: $0 [ssh|wg]"
        echo ""
        echo "  ssh  - Connect to instance via SSM (default)"
        echo "  wg   - Fetch WireGuard client config"
        ;;
esac
