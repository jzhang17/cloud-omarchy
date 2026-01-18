#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REGION="us-west-2"
INSTANCE_NAME="omarchy-cloud"

echo "=========================================="
echo "Omarchy Cloud - Destroy Instance"
echo "=========================================="
echo ""

# Find instance by name tag (any state except terminated)
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' \
    --output text 2>/dev/null | head -1 || echo "")

if [ -z "$INSTANCE_ID" ]; then
    echo "No instance found with name '$INSTANCE_NAME'"
    exit 0
fi

# Get instance info
INSTANCE_INFO=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,LaunchTime:LaunchTime}' \
    --output json)

STATE=$(echo "$INSTANCE_INFO" | jq -r '.State')
TYPE=$(echo "$INSTANCE_INFO" | jq -r '.Type')
LAUNCH=$(echo "$INSTANCE_INFO" | jq -r '.LaunchTime')

echo "Instance: $INSTANCE_ID"
echo "Type:     $TYPE"
echo "State:    $STATE"
echo "Launched: $LAUNCH"
echo ""

read -p "Are you sure you want to PERMANENTLY DELETE this instance? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Disconnect VPN if connected
if command -v wg &> /dev/null; then
    if sudo wg show wg0 &> /dev/null 2>&1; then
        echo "Disconnecting VPN..."
        sudo wg-quick down wg0 2>/dev/null || true
    fi
fi

# Terminate instance
echo "Terminating instance..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --output json > /dev/null

echo "Waiting for termination..."
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"

echo ""
echo "Instance terminated."
echo ""

# Clean up IAM resources
read -p "Also delete IAM role and security group? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleaning up IAM resources..."

    # Remove role from instance profile
    aws iam remove-role-from-instance-profile \
        --instance-profile-name omarchy-cloud-ssm-profile \
        --role-name omarchy-cloud-ssm-role 2>/dev/null || true

    # Delete instance profile
    aws iam delete-instance-profile \
        --instance-profile-name omarchy-cloud-ssm-profile 2>/dev/null || true

    # Detach policy from role
    aws iam detach-role-policy \
        --role-name omarchy-cloud-ssm-role \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

    # Delete role
    aws iam delete-role --role-name omarchy-cloud-ssm-role 2>/dev/null || true

    echo "Cleaning up security group..."
    aws ec2 delete-security-group \
        --region "$REGION" \
        --group-name omarchy-cloud-sg 2>/dev/null || true

    echo "Cleanup complete."
fi

echo ""
echo "=========================================="
echo "Instance Destroyed"
echo "=========================================="
echo ""
echo "To deploy a new instance: ./auto-deploy.sh"
echo ""
