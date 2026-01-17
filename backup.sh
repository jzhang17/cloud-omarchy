#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "GPU Streaming Workstation - Backup"
echo "=========================================="
echo ""

# Check if terraform state exists
if [ ! -f "terraform.tfstate" ]; then
    echo "No terraform.tfstate found. Cannot determine data volume."
    exit 1
fi

# Get data volume ID from Terraform output
DATA_VOLUME_ID=$(terraform output -raw data_volume_id 2>/dev/null)

if [ -z "$DATA_VOLUME_ID" ]; then
    echo "ERROR: Could not retrieve data volume ID from Terraform state."
    exit 1
fi

echo "Data Volume ID: $DATA_VOLUME_ID"
echo ""

# Get the AWS region from Terraform
AWS_REGION=$(terraform output -raw availability_zone 2>/dev/null | sed 's/[a-z]$//' || echo "us-west-2")

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_DESCRIPTION="gpu-streaming-workstation-backup-$TIMESTAMP"

echo "Creating EBS snapshot..."
echo "Description: $SNAPSHOT_DESCRIPTION"
echo ""

# Create the snapshot
SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --region "$AWS_REGION" \
    --volume-id "$DATA_VOLUME_ID" \
    --description "$SNAPSHOT_DESCRIPTION" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$SNAPSHOT_DESCRIPTION},{Key=Project,Value=gpu-streaming-workstation},{Key=SourceVolumeId,Value=$DATA_VOLUME_ID}]" \
    --query 'SnapshotId' \
    --output text)

echo "=========================================="
echo "Snapshot Created!"
echo "=========================================="
echo ""
echo "Snapshot ID: $SNAPSHOT_ID"
echo "Volume ID: $DATA_VOLUME_ID"
echo "Region: $AWS_REGION"
echo "Description: $SNAPSHOT_DESCRIPTION"
echo ""
echo "Check snapshot progress:"
echo "  aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID --query 'Snapshots[0].Progress'"
echo ""
echo "List all snapshots for this volume:"
echo "  aws ec2 describe-snapshots --filters Name=volume-id,Values=$DATA_VOLUME_ID"
echo ""
