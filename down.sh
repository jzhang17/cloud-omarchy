#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "GPU Streaming Workstation - Destroy"
echo "=========================================="
echo ""

# Check if terraform state exists
if [ ! -f "terraform.tfstate" ]; then
    echo "No terraform.tfstate found. Nothing to destroy."
    exit 0
fi

# Check if data volume deletion is requested
DELETE_DATA_VOLUME="${TF_VAR_delete_data_volume:-false}"

if [ "$DELETE_DATA_VOLUME" = "true" ]; then
    echo "WARNING: delete_data_volume=true"
    echo "The persistent data volume WILL BE DELETED!"
    echo ""
    read -p "Are you absolutely sure? Type 'DELETE' to confirm: " confirm
    if [ "$confirm" != "DELETE" ]; then
        echo "Destruction cancelled."
        exit 0
    fi
else
    echo "The persistent data volume will be PRESERVED."
    echo "To also delete the data volume, run:"
    echo "  TF_VAR_delete_data_volume=true ./down.sh"
    echo ""
fi

# Get current state info before destroying
if terraform state list | grep -q "aws_ebs_volume.data"; then
    DATA_VOLUME_ID=$(terraform output -raw data_volume_id 2>/dev/null || echo "unknown")
    echo "Data Volume ID: $DATA_VOLUME_ID"
fi

echo ""
read -p "Do you want to destroy the infrastructure? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Destruction cancelled."
    exit 0
fi

echo ""

if [ "$DELETE_DATA_VOLUME" = "true" ]; then
    # Full destroy including data volume
    echo "Destroying all resources including data volume..."
    terraform destroy -auto-approve
else
    # Destroy everything except the data volume
    echo "Destroying instance and security group (preserving data volume)..."

    # First, remove the volume attachment
    if terraform state list | grep -q "aws_volume_attachment.data"; then
        terraform destroy -target=aws_volume_attachment.data -auto-approve
    fi

    # Then destroy the instance
    if terraform state list | grep -q "aws_instance.streaming_workstation"; then
        terraform destroy -target=aws_instance.streaming_workstation -auto-approve
    fi

    # Then the security group
    if terraform state list | grep -q "aws_security_group.streaming_workstation"; then
        terraform destroy -target=aws_security_group.streaming_workstation -auto-approve
    fi

    echo ""
    echo "=========================================="
    echo "Instance destroyed. Data volume preserved."
    echo "=========================================="
    echo ""
    echo "Data Volume ID: $DATA_VOLUME_ID"
    echo ""
    echo "To redeploy with the same data volume, just run ./up.sh"
    echo ""
    echo "To completely remove everything including data:"
    echo "  TF_VAR_delete_data_volume=true ./down.sh"
    echo ""
fi

echo "Destruction complete."
