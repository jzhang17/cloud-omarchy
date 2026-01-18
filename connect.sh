#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Get region from terraform variables
REGION=$(awk '/variable "aws_region"/,/}/' variables.tf | grep default | sed 's/.*= *"\([^"]*\)".*/\1/')

# Get instance ID from terraform state
if [ ! -f "terraform.tfstate" ]; then
    echo "ERROR: No terraform.tfstate found"
    echo "Run ./up.sh first to deploy the instance."
    exit 1
fi

INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: No instance found in terraform state"
    echo "Run ./up.sh to deploy."
    exit 1
fi

# Get current instance info from AWS
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress}' \
    --output json 2>/dev/null || echo '{"State":"not-found"}')

STATE=$(echo "$INSTANCE_INFO" | jq -r '.State')
PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.IP // "none"')

echo "=========================================="
echo "GPU Streaming Workstation - Connect"
echo "=========================================="
echo ""
echo "Instance: $INSTANCE_ID"
echo "Region:   $REGION"
echo "State:    $STATE"
echo "IP:       $PUBLIC_IP"
echo ""

if [ "$STATE" != "running" ]; then
    echo "Instance is not running."
    if [ "$STATE" == "stopped" ]; then
        echo "Run ./up.sh to start it."
    fi
    exit 1
fi

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
        aws ssm start-session \
            --target "$INSTANCE_ID" \
            --region "$REGION" \
            --document-name AWS-StartInteractiveCommand \
            --parameters 'command="sudo cat /home/arch/wg0-client.conf"'
        ;;
    *)
        echo "Usage: $0 [ssh|wg]"
        echo ""
        echo "  ssh  - Connect to instance via SSM (default)"
        echo "  wg   - Fetch WireGuard client config"
        ;;
esac
