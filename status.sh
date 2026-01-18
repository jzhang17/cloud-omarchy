#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Get region from terraform variables
REGION=$(awk '/variable "aws_region"/,/}/' variables.tf | grep default | sed 's/.*= *"\([^"]*\)".*/\1/')

echo "=========================================="
echo "GPU Streaming Workstation - Status"
echo "=========================================="
echo ""
echo "Region: $REGION"
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

# Check terraform state
if [ ! -f "terraform.tfstate" ]; then
    echo "Instance: NOT DEPLOYED"
    echo ""
    echo "Run ./up.sh to deploy."
    exit 0
fi

# Try to get instance ID from terraform
INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ]; then
    echo "Instance: NOT DEPLOYED"
    echo ""
    echo "Run ./up.sh to deploy."
    exit 0
fi

# Get instance info from AWS
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,IP:PublicIpAddress}' \
    --output json 2>/dev/null || echo '{"State":"terminated"}')

STATE=$(echo "$INSTANCE_INFO" | jq -r '.State')
TYPE=$(echo "$INSTANCE_INFO" | jq -r '.Type // "N/A"')
IP=$(echo "$INSTANCE_INFO" | jq -r '.IP // "none"')

echo "EC2 Instance:"
echo "  ID: $INSTANCE_ID"
echo "  State: $STATE"
echo "  Type: $TYPE"
echo "  Public IP: $IP"
echo ""

# Billing info based on state
echo "Billing:"
if [ "$STATE" = "running" ]; then
    echo "  Compute: ~\$0.526/hr (g4dn.xlarge)"
    echo "  Storage: ~\$19/mo (40GB root + 200GB data)"
    echo "  Status: CHARGING"
elif [ "$STATE" = "stopped" ]; then
    echo "  Compute: \$0 (stopped)"
    echo "  Storage: ~\$19/mo (40GB root + 200GB data)"
    echo "  Status: Storage only"
else
    echo "  Status: Instance not found"
fi
echo ""

# Commands
echo "Commands:"
if [ "$STATE" = "running" ]; then
    echo "  Stop:     ./down.sh      (~30 sec, stops compute billing)"
    echo "  Connect:  ./connect.sh"
elif [ "$STATE" = "stopped" ]; then
    echo "  Start:    ./up.sh        (~60 sec)"
    echo "  Destroy:  DESTROY=true ./down.sh"
else
    echo "  Deploy:   ./up.sh"
fi
echo ""
