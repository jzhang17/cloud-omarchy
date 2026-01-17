#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

STATE_FILE="$SCRIPT_DIR/.state.json"
REGION="us-west-1"

echo "=========================================="
echo "GPU Streaming Workstation - Status"
echo "=========================================="
echo ""

# Check for auto-deploy process
if pgrep -f "auto-deploy.sh" > /dev/null 2>&1; then
    echo "Auto-deploy: RUNNING (PID $(pgrep -f 'auto-deploy.sh'))"
    if [ -f ".auto-deploy.log" ]; then
        echo "Latest log:"
        tail -3 .auto-deploy.log | sed 's/^/  /'
    fi
    echo ""
fi

# Check quota status
echo "GPU Quota Status (us-west-1):"
QUOTA=$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --region "$REGION" \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "unknown")
echo "  G/VT Instance vCPUs: $QUOTA"

# Check pending request if exists
REQUEST_STATUS=$(aws service-quotas get-requested-service-quota-change \
    --request-id "ef52070396ff4b22ba65919d400518bfsIgZFx8h" \
    --region "$REGION" \
    --query 'RequestedQuota.Status' \
    --output text 2>/dev/null || echo "none")
if [ "$REQUEST_STATUS" != "none" ]; then
    echo "  Quota Request: $REQUEST_STATUS"
fi
echo ""

# Check state file
if [ ! -f "$STATE_FILE" ]; then
    echo "Instance: NOT DEPLOYED (no state file)"
    echo ""
    echo "Run ./up.sh or ./auto-deploy.sh to deploy."
    exit 0
fi

INSTANCE_ID=$(jq -r '.instance_id // empty' "$STATE_FILE")
VOLUME_ID=$(jq -r '.volume_id // empty' "$STATE_FILE")
SG_ID=$(jq -r '.security_group_id // empty' "$STATE_FILE")
PUBLIC_IP=$(jq -r '.public_ip // empty' "$STATE_FILE")

echo "State File: $STATE_FILE"
echo ""

# Instance status
if [ -n "$INSTANCE_ID" ]; then
    echo "EC2 Instance:"
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,IP:PublicIpAddress,AZ:Placement.AvailabilityZone}' \
        --output json 2>/dev/null || echo '{"State":"not-found"}')

    STATE=$(echo "$INSTANCE_INFO" | jq -r '.State')
    TYPE=$(echo "$INSTANCE_INFO" | jq -r '.Type // "N/A"')
    IP=$(echo "$INSTANCE_INFO" | jq -r '.IP // "N/A"')
    AZ=$(echo "$INSTANCE_INFO" | jq -r '.AZ // "N/A"')

    echo "  ID: $INSTANCE_ID"
    echo "  State: $STATE"
    echo "  Type: $TYPE"
    echo "  Public IP: $IP"
    echo "  AZ: $AZ"
    echo ""
else
    echo "EC2 Instance: Not created"
    echo ""
fi

# Volume status
if [ -n "$VOLUME_ID" ]; then
    echo "EBS Data Volume:"
    VOLUME_INFO=$(aws ec2 describe-volumes \
        --region "$REGION" \
        --volume-ids "$VOLUME_ID" \
        --query 'Volumes[0].{State:State,Size:Size,AZ:AvailabilityZone}' \
        --output json 2>/dev/null || echo '{"State":"not-found"}')

    VSTATE=$(echo "$VOLUME_INFO" | jq -r '.State')
    VSIZE=$(echo "$VOLUME_INFO" | jq -r '.Size // "N/A"')
    VAZ=$(echo "$VOLUME_INFO" | jq -r '.AZ // "N/A"')

    echo "  ID: $VOLUME_ID"
    echo "  State: $VSTATE"
    echo "  Size: ${VSIZE}GB"
    echo "  AZ: $VAZ"
    echo ""
fi

# Security group status
if [ -n "$SG_ID" ]; then
    echo "Security Group:"
    SG_EXISTS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "not-found")

    if [ "$SG_EXISTS" != "not-found" ]; then
        echo "  ID: $SG_ID (exists)"
    else
        echo "  ID: $SG_ID (NOT FOUND)"
    fi
    echo ""
fi

# Connection info
if [ -n "$INSTANCE_ID" ] && [ "$STATE" == "running" ]; then
    echo "=========================================="
    echo "Connection Commands:"
    echo "=========================================="
    echo ""
    echo "SSM Session:"
    echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
    echo ""
    echo "Or use: ./connect.sh"
    echo ""
fi
