#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

echo "=========================================="
echo "Omarchy Cloud - Start Instance"
echo "=========================================="
echo ""

# Find instance by name tag
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=stopped,running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
    echo "No instance found with name '$INSTANCE_NAME'"
    echo "Run ./auto-deploy.sh to create a new instance."
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

if [ "$STATE" = "running" ]; then
    echo "Instance is already running!"
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    echo "Public IP: $PUBLIC_IP"
    echo ""
    echo "Next steps:"
    echo "  1. Connect VPN:    ./vpn.sh up"
    echo "  2. Start stream:   ./stream.sh"
    echo "  3. Open Moonlight and connect to 10.200.200.1"
    exit 0
fi

if [ "$STATE" != "stopped" ]; then
    echo "Instance is in '$STATE' state, cannot start."
    exit 1
fi

# Start the instance
echo "Starting instance..."
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --output json > /dev/null

# Wait for running
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

# Get new public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "Instance is now running!"
echo "Public IP: $PUBLIC_IP"
echo ""

# Update WireGuard config with new IP
if [ -f "wg0-client.conf" ]; then
    # Get old endpoint IP from config
    OLD_IP=$(grep "Endpoint" wg0-client.conf | sed 's/.*Endpoint = \([^:]*\).*/\1/')
    if [ "$OLD_IP" != "$PUBLIC_IP" ]; then
        echo "Updating WireGuard config with new IP..."
        sed -i '' "s/Endpoint = $OLD_IP:/Endpoint = $PUBLIC_IP:/" wg0-client.conf
        echo "Updated wg0-client.conf"
    fi
fi

# Wait for SSM agent
echo ""
echo "Waiting for SSM agent to be ready..."
for i in {1..30}; do
    STATUS=$(aws ssm describe-instance-information \
        --region "$REGION" \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "None")
    if [ "$STATUS" = "Online" ]; then
        echo "SSM agent is ready!"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

echo ""
echo "=========================================="
echo "Instance Ready!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Connect VPN:    ./vpn.sh up"
echo "  2. Start stream:   ./stream.sh"
echo "  3. Open Moonlight and connect to 10.200.200.1"
echo ""
