#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Get region from terraform variables
REGION=$(awk '/variable "aws_region"/,/}/' variables.tf | grep default | sed 's/.*= *"\([^"]*\)".*/\1/')

echo "=========================================="
echo "GPU Streaming Workstation - Stop"
echo "=========================================="
echo ""

# Check for full destroy flag
if [ "${DESTROY:-}" = "true" ] || [ "${TF_VAR_delete_data_volume:-}" = "true" ]; then
    echo "DESTROY mode - will terminate instance and delete all resources"
    echo ""

    if [ "${TF_VAR_delete_data_volume:-}" = "true" ]; then
        echo "WARNING: Data volume will also be DELETED!"
        read -p "Type 'DELETE' to confirm: " confirm
        if [ "$confirm" != "DELETE" ]; then
            echo "Cancelled."
            exit 0
        fi
        terraform destroy -auto-approve
    else
        # Just destroy instance, keep data volume
        terraform destroy -auto-approve
    fi
    echo ""
    echo "Destroy complete."
    exit 0
fi

# Normal operation: just stop the instance (fast!)
if [ ! -f "terraform.tfstate" ]; then
    echo "No terraform.tfstate found. Nothing to stop."
    exit 0
fi

INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ]; then
    echo "No instance found in terraform state."
    exit 0
fi

# Check instance state
STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")

if [ "$STATE" = "stopped" ]; then
    echo "Instance $INSTANCE_ID is already stopped."
    echo ""
    echo "Ongoing charges: ~\$16/mo for 200GB data volume"
    echo ""
    echo "To fully destroy (stop all charges except data volume):"
    echo "  DESTROY=true ./down.sh"
    echo ""
    echo "To delete everything including data:"
    echo "  TF_VAR_delete_data_volume=true ./down.sh"
    exit 0
fi

if [ "$STATE" = "not-found" ] || [ "$STATE" = "terminated" ]; then
    echo "Instance $INSTANCE_ID not found or already terminated."
    exit 0
fi

if [ "$STATE" != "running" ]; then
    echo "Instance is in state: $STATE (not running)"
    echo "Waiting for it to settle..."
    sleep 10
fi

echo "Stopping instance $INSTANCE_ID..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null

echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"

echo ""
echo "=========================================="
echo "Instance Stopped!"
echo "=========================================="
echo ""
echo "Compute charges: STOPPED"
echo "Storage charges: ~\$19/mo (40GB root + 200GB data)"
echo ""
echo "To restart:  ./up.sh"
echo "To destroy:  DESTROY=true ./down.sh"
echo ""
