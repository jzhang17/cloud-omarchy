#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

echo "=========================================="
echo "Omarchy Cloud - Stop Instance"
echo "=========================================="
echo ""

# Find instance by name tag
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
    echo "No instance found with name '$INSTANCE_NAME'"
    exit 1
fi

# Get current state
STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

echo "Instance: $INSTANCE_ID"
echo "Current state: $STATE"
echo ""

if [ "$STATE" = "stopped" ]; then
    echo "Instance is already stopped."
    exit 0
fi

if [ "$STATE" = "stopping" ]; then
    echo "Instance is already stopping..."
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "Instance stopped."
    exit 0
fi

if [ "$STATE" != "running" ]; then
    echo "Instance is in '$STATE' state."
    exit 1
fi

# Disconnect VPN first if connected
if command -v wg &> /dev/null; then
    if sudo wg show wg0 &> /dev/null 2>&1; then
        echo "Disconnecting VPN..."
        sudo wg-quick down wg0 2>/dev/null || true
    fi
fi

# Stop the instance
echo "Stopping instance..."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --output json > /dev/null

echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

echo ""
echo "=========================================="
echo "Instance Stopped"
echo "=========================================="
echo ""
echo "Billing:"
echo "  - Compute: $0/hr (stopped)"
echo "  - Storage: ~$16/mo (200GB gp3)"
echo ""
echo "To start again: ./start.sh"
echo "To destroy completely: ./destroy.sh"
echo ""
