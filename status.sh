#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

echo "=========================================="
echo "Omarchy Cloud - Status"
echo "=========================================="
echo ""
echo "Region: $REGION"
echo ""

# Check GPU quota
echo "GPU Quota:"
QUOTA=$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --region "$REGION" \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "unknown")
echo "  G/VT Instance vCPUs: $QUOTA"
echo ""

# Find instance by name tag
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' \
    --output text 2>/dev/null | head -1 || echo "")

if [ -z "$INSTANCE_ID" ]; then
    echo "Instance: NOT DEPLOYED"
    echo ""
    echo "Run ./auto-deploy.sh to deploy."
    exit 0
fi

# Get instance info from AWS
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,IP:PublicIpAddress,LaunchTime:LaunchTime}' \
    --output json 2>/dev/null || echo '{"State":"not-found"}')

STATE=$(echo "$INSTANCE_INFO" | jq -r '.State')
TYPE=$(echo "$INSTANCE_INFO" | jq -r '.Type // "N/A"')
IP=$(echo "$INSTANCE_INFO" | jq -r '.IP // "none"')
LAUNCH=$(echo "$INSTANCE_INFO" | jq -r '.LaunchTime // "N/A"')

echo "EC2 Instance:"
echo "  ID:       $INSTANCE_ID"
echo "  State:    $STATE"
echo "  Type:     $TYPE"
echo "  Public IP: $IP"
echo "  Launched: $LAUNCH"
echo ""

# Check SSM agent status if running
if [ "$STATE" = "running" ]; then
    SSM_STATUS=$(aws ssm describe-instance-information \
        --region "$REGION" \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "Unknown")
    echo "  SSM Agent: $SSM_STATUS"
    echo ""
fi

# VPN status
echo "VPN:"
if command -v wg &> /dev/null && sudo wg show wg0 &> /dev/null 2>&1; then
    echo "  Status: CONNECTED"
    ENDPOINT=$(sudo wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1)
    echo "  Endpoint: $ENDPOINT"
else
    echo "  Status: DISCONNECTED"
fi
echo ""

# Billing info based on state
echo "Billing:"
if [ "$STATE" = "running" ]; then
    echo "  Compute: ~\$0.526/hr (g4dn.xlarge)"
    echo "  Storage: ~\$16/mo (200GB gp3)"
    echo "  Status:  CHARGING"
elif [ "$STATE" = "stopped" ]; then
    echo "  Compute: \$0 (stopped)"
    echo "  Storage: ~\$16/mo (200GB gp3)"
    echo "  Status:  Storage only"
else
    echo "  Status: Instance in $STATE state"
fi
echo ""

# Commands
echo "Commands:"
if [ "$STATE" = "running" ]; then
    echo "  ./vpn.sh up      Connect VPN"
    echo "  ./stream.sh      Start streaming"
    echo "  ./connect.sh     SSM shell"
    echo "  ./stop.sh        Stop instance"
elif [ "$STATE" = "stopped" ]; then
    echo "  ./start.sh       Start instance"
    echo "  ./destroy.sh     Delete instance"
else
    echo "  ./auto-deploy.sh Deploy new instance"
fi
echo ""
